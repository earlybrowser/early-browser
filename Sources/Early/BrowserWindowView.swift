// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import EarlyWeb
import SwiftUI

private struct FolderBounceDisplacementKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

private extension EnvironmentValues {
    var folderBounceDisplacement: CGFloat {
        get { self[FolderBounceDisplacementKey.self] }
        set { self[FolderBounceDisplacementKey.self] = newValue }
    }
}

struct BrowserWindowView: View {
    /// Folders and pinned tabs share one island geometry at every sidebar width.
    private enum PinnedIsland {
        static let height: CGFloat = 34
        static let cornerRadius: CGFloat = 10
    }

    @Bindable var model: BrowserWindowModel
    private var sidebarAutoHides: Bool { model.preferences.sidebarAutoHides }
    @State private var sidebarHovered = false
    @State private var resizeStartWidth: Double?
    @State private var tabFrames: [UUID: CGRect] = [:]
    @State private var folderHitFrames: [UUID: CGRect] = [:]
    @State private var sectionFrames: [Bool: CGRect] = [:]
    @State private var dropAreas: [String: CGRect] = [:]
    // Shared stable identity for a tab or folder being reordered.
    @GestureState private var draggingTab: UUID?
    @State private var dragLayout: SidebarReorderLayout?
    @State private var dragPoint: CGPoint = .zero
    @State private var dragTranslation: CGSize = .zero
    @State private var dragSourceFrame: CGRect = .zero
    @State private var frozenFrames: [UUID: CGRect] = [:]
    @State private var dropFolder: UUID?
    @State private var pendingFolder: UUID?
    @State private var previousDragPoint: CGPoint?
    @State private var insertionContainer: DragContainer?
    @State private var insertionSiblings: [UUID] = []
    @State private var insertionIndex: Int?
    @State private var dragFeedbackTarget: DragFeedbackTarget?
    @State private var reservedFolderSlot: UUID?
    @State private var revealDropSections = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @State private var folderEditor = false
    @State private var editingFolder: UUID?
    @State private var folderParent: UUID?
    @State private var folderName = ""
    #if DEBUG
    @State private var folderToggleActionCount = 0

    private var testRuntimeValue: String {
        "Tabs \(model.openTabs.count) · Views \(model.webViews.liveViewCount) · Created \(model.webViews.creationCount) · \(model.persistence.isSaving ? "Saving" : "Saved")"
    }
    #endif
    @State private var hoveredTab: UUID?
    @State private var hoveredFolder: UUID?
    @State private var hoveredFolderGroups: Set<UUID> = []
    @State private var folderBounceEvent: FolderBounceEvent?
    @State private var sidebarPointer = SidebarPointer()
    @FocusState private var focusedSidebarControl: SidebarControl?
    private var sidebarVisible: Bool { !sidebarAutoHides || sidebarHovered }
    private var showsFolderDragTargets: Bool {
        guard let viewport = sectionFrames[false], let divider = dropAreas["divider"] else { return false }
        return SidebarFolderPreview.showsDragTargets(isDragging: draggingTab != nil, at: dragPoint,
                                                     viewport: viewport, divider: divider)
    }
    private var folderDragAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.18)
    }
    private var folderExpansionAnimation: Animation? {
        reduceMotion ? nil : .spring(duration: 0.16, bounce: 0.18)
    }
    private var sidebarMotion: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.20)
    }

    private var sidebarResizeHandle: some View {
        Rectangle()
            .fill(Color.primary.opacity(resizeStartWidth == nil ? 0.001 : 0.12))
            .frame(width: 6)
            .contentShape(Rectangle())
            .offset(x: 3)
            .onHover { inside in
                (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if resizeStartWidth == nil { resizeStartWidth = model.sidebarWidth }
                    model.sidebarWidth = SidebarWidth.clamped((resizeStartWidth ?? model.sidebarWidth) + value.translation.width)
                }
                .onEnded { _ in
                    resizeStartWidth = nil
                    model.finishSidebarResize()
                    NSCursor.arrow.set()
                })
            .accessibilityLabel("Sidebar width")
            .accessibilityValue("\(Int(model.sidebarWidth)) points")
            .accessibilityIdentifier("sidebar.resize")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: model.sidebarWidth = SidebarWidth.clamped(model.sidebarWidth + 16)
                case .decrement: model.sidebarWidth = SidebarWidth.clamped(model.sidebarWidth - 16)
                @unknown default: return
                }
                model.finishSidebarResize()
            }
    }

    // Pointer samples are not observable: redraw only when group membership
    // changes. Retain the last sample to recompute hover after scrolling/layout.
    private final class SidebarPointer {
        var location: CGPoint?
    }

    private enum SidebarControl: Hashable {
        case tab(UUID), close(UUID), favorite(UUID), folder(UUID), folderToggle(UUID)
    }

    private struct DragContainer: Equatable {
        let section: TabStore.Section
        let parent: UUID?
    }

    private struct DragFeedbackTarget: Equatable {
        let container: DragContainer
        let index: Int?
    }

    private struct FolderBounceEvent: Equatable {
        let id = UUID()
        let folders: Set<UUID>
    }

    private enum SidebarItem: Identifiable {
        case pinnedStart, pinnedEnd, divider, newTab
        case tab(BrowserTab, Int)
        case folder(BrowserFolder, Int)
        case folderEnd(BrowserFolder, Int)

        var id: String {
            switch self {
            case .pinnedStart: "pinned-start"
            case .pinnedEnd: "pinned-end"
            case .divider: "divider"
            case .newTab: "new-tab"
            case .tab(let tab, _): "tab-\(tab.id)"
            case .folder(let folder, _): "folder-\(folder.id)"
            case .folderEnd(let folder, _): "folder-end-\(folder.id)"
            }
        }
    }

    private var sidebarItems: [SidebarItem] {
        sidebarItems(in: model.coordinator.activeSpaceID)
    }

    private func sidebarItems(in spaceID: UUID) -> [SidebarItem] {
        let pins = folderItems(in: spaceID, parent: nil, depth: 0)
        let revealsDropSections = spaceID == model.coordinator.activeSpaceID && revealDropSections
        return (pins.isEmpty && !revealsDropSections ? [] : [.pinnedStart] + pins + [.pinnedEnd])
            + [.divider, .newTab] + model.coordinator.tabStore.todayTabs(in: spaceID).map { .tab($0, 0) }
    }

    private func folderItems(in spaceID: UUID, parent: UUID?, depth: Int) -> [SidebarItem] {
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
                if preview.showsPanel {
                    items.append(.folderEnd(folder, depth))
                }
                return items
            }
        }
    }

    private func folderHasChildren(_ id: UUID, in spaceID: UUID? = nil) -> Bool {
        !model.coordinator.tabStore.pinnedItems(in: spaceID ?? model.coordinator.activeSpaceID, parentID: id).isEmpty
    }

    private func folderPreview(_ folder: BrowserFolder) -> SidebarFolderPreview {
        SidebarFolderPreview(isExpanded: folder.isExpanded, hasChildren: folderHasChildren(folder.id, in: folder.spaceID),
                             isDragSource: folder.id == draggingTab, receivesSlot: reservedFolderSlot == folder.id)
    }

    private func isFolderOpen(_ folder: BrowserFolder) -> Bool {
        folder.id != draggingTab && folder.isExpanded
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

    /// The pinned sidebar belongs to the continuous window chrome, not a
    /// separate rounded island. Only the floating sidebar needs inset corners.
    private var sidebarCornerRadius: CGFloat {
        sidebarAutoHides ? max(Self.windowCornerRadius - 3, 4) : 0
    }

    var body: some View {
        ZStack(alignment: .leading) {
            ZStack {
                if model.activePage != nil {
                    Color(nsColor: .textBackgroundColor)
                } else if reduceTransparency || contrast == .increased {
                    Color(nsColor: .windowBackgroundColor)
                } else {
                    // A softly lifted empty canvas over the shared native blur.
                    Color.white.opacity(colorScheme == .dark ? 0.01 : 0.08)
                }
                WebContentView(view: model.activePage?.view, focusRequest: model.contentFocusRequest,
                               canFocus: model.coordinator.commandBar == nil,
                               hasDialog: model.activePage?.hasDialog == true)
                    .accessibilityIdentifier("browser.content")
                if let error = model.activePage?.failure {
                    VStack(spacing: 12) {
                        Label("Unable to open this page", systemImage: "exclamationmark.triangle")
                            .font(.headline)
                        Text(error).multilineTextAlignment(.center)
                        Button("Try Again") { model.perform(.reload) }
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
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) { pageLoadingLine }
            .clipShape(RoundedRectangle(cornerRadius: contentCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: contentCornerRadius)
                    .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.30 : 0.08), lineWidth: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .padding(.leading, sidebarAutoHides ? 0 : model.sidebarWidth + 6)

            sidebar
                .background {
                    if sidebarAutoHides {
                        // Floating chrome must stay legible over web content.
                        BrowserChromeBackground(spaceColor: model.preferences.spaceThemes ? (model.coordinator.activeSpace?.color ?? .gray) : .gray,
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
        }
        .animation(sidebarMotion, value: sidebarAutoHides)
        .animation(sidebarMotion, value: sidebarVisible)
        .padding(6)
        // One shared surface for the outer frame and pinned sidebar. Only the
        // clipped page area is inset into it; no sidebar tint or seam on top.
        .background(BrowserChromeBackground(spaceColor: model.preferences.spaceThemes ? (model.coordinator.activeSpace?.color ?? .gray) : .gray,
                                            allowsTransparency: model.preferences.translucentChrome))
        .overlay(alignment: .topTrailing) {
            if let toast = model.toast {
                Label(toast.message, systemImage: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background {
                        if reduceTransparency || contrast == .increased {
                            RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor))
                        } else {
                            RoundedRectangle(cornerRadius: 12).fill(.thickMaterial)
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.4 : 0.16), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                    .padding(20)
                    .allowsHitTesting(false)
                    .accessibilityLabel(toast.message)
                    .accessibilityIdentifier(toast.accessibilityIdentifier)
                    .transition(.opacity)
                    .task(id: toast.id) {
                        do { try await Task.sleep(for: .seconds(2)) } catch { return }
                        if model.toast?.id == toast.id { model.toast = nil }
                    }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.toast != nil)
        .overlay(alignment: .leading) {
            if sidebarAutoHides && !sidebarVisible {
                Color.clear
                    .frame(width: 2)
                    .contentShape(Rectangle())
                    .onTapGesture { sidebarHovered = true }
                    .accessibilityLabel("Reveal sidebar")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("sidebar.reveal")
            }
        }
        // Track the stationary window surface, not the animated sidebar or the
        // disappearing edge target. Their exit events can otherwise cancel a
        // reveal and repeatedly restart it beneath a stationary pointer.
        .onContinuousHover { phase in
            guard sidebarAutoHides else { return }
            switch phase {
            case .active(let point):
                // Retain across the edge-to-panel gutter as well as the panel.
                // Entering its old footprint alone must never reveal it.
                let inside = resizeStartWidth != nil || (point.x >= 0 && point.x < (sidebarHovered ? model.sidebarWidth + 6 : 2))
                if sidebarHovered != inside { sidebarHovered = inside }
            case .ended:
                sidebarHovered = false
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background {
            #if DEBUG
            if model.isTesting {
                HStack(spacing: 0) {
                    TestWindowState().frame(width: 1, height: 1)
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
        .onChange(of: sidebarVisible, initial: true) { _, visible in
            model.sidebarIsHidden = !visible
            if !visible {
                sidebarPointer.location = nil
                hoveredFolderGroups = []
            }
        }
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
                if success { model.save() } else { model.notice = "Could not save folder. Use a name and a parent with room for a subfolder (two nesting levels maximum)." }
                folderEditor = false
            }
            .keyboardShortcut(.defaultAction)
            .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
          }.padding(24).frame(width: 340)
        }
        .onChange(of: folderEditor) { _, value in model.folderEditorIsPresented = value }
        .onDisappear {
            endDrag()
            model.cancelSpaceSwipePresentation()
            model.folderEditorIsPresented = false
            model.save()
            model.webViews.discardAll()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 8) {
                navigationControls
                addressBar.background(dropArea("address"))
            }
            if !model.favorites.isEmpty || revealDropSections {
                favoritesSection
            }
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
            }
            #endif
            sidebarFooter
        }
        .padding(.horizontal, sidebarAutoHides ? 5 : 2)
        .padding(.top, sidebarAutoHides ? 7 : 4)
        .padding(.bottom, sidebarAutoHides ? 17 : 14)
        .frame(width: model.sidebarWidth + (sidebarAutoHides ? 3 : 0))
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .contextMenu {
            Button("New Tab") { model.perform(.presentCommandBar(.newTab)) }
            Button("New Folder") { editFolder(nil, parent: nil) }
            Divider()
            Button("New Space…") { model.perform(.newSpace) }
            if let space = model.coordinator.activeSpace { SpaceActions(model: model, space: space) }
        }
        .background(SpaceSwipeMonitor(model: model,
            enabled: model.preferences.spaceSwipes && sidebarVisible && draggingTab == nil && resizeStartWidth == nil && !folderEditor))
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
                }
            }
            tabFrames = frames
            folderHitFrames = headers
            sectionFrames = sections
            dropAreas = areas
            refreshFolderPanelHover()
            guard draggingTab != nil else { return }
            // Rebuild hit testing only after ALL measurements from this layout
            // pass agree; cross-folder moves change headers and ends together.
            frozenFrames = frames
            // Insertion previews can move a header underneath a stationary
            // pointer. Re-resolve its folder before rebuilding sibling order.
            updateFolderHover(at: dragPoint)
            refreshCurrentDrag()
        }
        .onChange(of: draggingTab) { _, id in
            if id == nil { endDrag() }
            else { folderBounceEvent = nil }
        }
        .onChange(of: model.coordinator.activeSpaceID) { _, _ in
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

    private func spaceContents(for space: BrowserSpace) -> some View {
        let active = space.id == model.coordinator.activeSpaceID
        let items = sidebarItems(in: space.id)
        let hasPins = !model.coordinator.tabStore.pinnedItems(in: space.id, parentID: nil).isEmpty
        let selection = model.coordinator.session.selectionBySpace[space.id]
        return VStack(alignment: .leading, spacing: 16) {
            Text(space.name)
                .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .contentTransition(.opacity)
                .accessibilityAddTraits(.isHeader)
                .contextMenu {
                    SpaceActions(model: model, space: space)
                    Button("New Space…") { model.perform(.newSpace) }
                }
            ScrollViewReader { scroll in
                ScrollView {
                    // Pins and Today share a scroll region: many persistent pins
                    // must not push Today or New Tab outside the reachable sidebar.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // One identity domain: moving the same UUID between two
                        // sibling ForEach collections can retain a stale lazy row.
                        ForEach(items) { item in
                            Group {
                            switch item {
                            case .pinnedStart:
                                Group {
                                    if !hasPins {
                                        Text("Pins").font(.callout).foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity).frame(height: 34)
                                            .accessibilityIdentifier("sidebar.pinned.dropTarget")
                                    } else {
                                        Color.clear.frame(height: 4).accessibilityHidden(true)
                                    }
                                }
                                    .background(dropArea("pinned"))
                            case .pinnedEnd:
                                Color.clear.frame(height: active && hasPins && needsPinInsertionSpace(in: nil) ? 38 : 4)
                                    .background(dropArea("pinnedEnd"))
                                    .accessibilityHidden(true)
                            case .divider:
                                Divider().padding(.vertical, 8)
                                    .background(dropArea("divider"))
                            case .newTab:
                                newTabButton
                                    .background(dropArea("regular"))
                            case .tab(let tab, let depth):
                                tabRow(tab, selected: tab.id == selection, requestsArtwork: active)
                                    .padding(.leading, CGFloat(min(depth, 8)) * 12)
                                    .padding(.trailing, CGFloat(min(depth, 8)) * 4)
                            case .folder(let folder, let depth):
                                folderRow(folder).padding(.leading, CGFloat(min(depth, 8)) * 12)
                                    .padding(.trailing, CGFloat(min(depth, 8)) * 4)
                            case .folderEnd(let folder, let depth):
                                Color.clear.frame(height: folderPreview(folder).footerHeight)
                                    .padding(.leading, CGFloat(min(depth, 8)) * 12)
                                    .padding(.trailing, CGFloat(min(depth, 8)) * 4)
                                    .anchorPreference(key: FolderBoundaries.self, value: .bounds) {
                                        [.end(folder.id): $0]
                                    }
                                    .offset(previewOffset(folder.id))
                                    .animation(draggingTab == nil || reduceMotion ? nil : .easeInOut(duration: 0.16), value: previewOffset(folder.id))
                                    .background(dropArea("folderEnd.\(folder.id)"))
                                    .accessibilityHidden(true)
                            }
                            }
                            // Keep the gesture mounted while neighboring rows fill
                            // its old space. Only the destination owns a drop slot.
                            .transition(.opacity)
                            .frame(height: vacatesSourceRow(item) ? 0 : nil)
                            .padding(.bottom, vacatesSourceRow(item) || item.id == items.last?.id ? 0 : SidebarFolderBounce.rowSpacing)
                            .animation(folderDragAnimation, value: vacatesSourceRow(item))
                            .id(item.id)
                        }
                    }
                    .backgroundPreferenceValue(FolderBoundaries.self) { anchors in
                        pinnedGroupBackgrounds(anchors: anchors)
                    }
                }
                .frame(maxHeight: .infinity)
                .accessibilityIdentifier(active ? "sidebar.tabs" : "sidebar.tabs.preview.\(space.id)")
                .background(sectionFrame(favorites: false))
                .task(id: active ? model.sidebarReveal?.id : nil) {
                    guard let request = model.sidebarReveal, request.spaceID == space.id else { return }
                    // Let the moved row enter the destination's lazy layout first.
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

    private var spacePager: some View {
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

    private var sidebarFooter: some View {
        SpaceFooter(model: model)
    }

    private func tabRow(_ tab: BrowserTab, selected: Bool, requestsArtwork: Bool) -> some View {
        let focused = focusedSidebarControl == .tab(tab.id) || focusedSidebarControl == .close(tab.id)
        let cornerRadius: CGFloat = tab.pinnedURL == nil ? 7 : PinnedIsland.cornerRadius
        return HStack(spacing: tab.hasNavigatedFromPin ? 1 : 4) {
            if tab.pinnedURL != nil {
                PinnedTabIcon(tab: tab, favicons: model.webViews.favicons, page: model.webViews.pages[tab.id],
                              reset: { model.perform(.resetPinnedTab(tab.id)) }, requestsArtwork: requestsArtwork)
            }
            Button { model.perform(.selectTab(tab.id)) } label: {
                HStack(spacing: tab.hasNavigatedFromPin ? 3 : 8) {
                    if tab.pinnedURL == nil {
                        TabArtwork(tab: tab, store: model.webViews.favicons, page: model.webViews.pages[tab.id],
                                   size: 16, requestsArtwork: requestsArtwork)
                    }
                    if tab.hasNavigatedFromPin {
                        Text("/").foregroundStyle(.tertiary).accessibilityHidden(true)
                    }
                    if model.webViews.pages[tab.id]?.isPlayingMedia == true {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel("Media playing")
                    }
                    Text(tab.displayTitle).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(tab.isOpen ? .primary : .secondary)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(SidebarButtonStyle())
            .focused($focusedSidebarControl, equals: .tab(tab.id))
            .accessibilityIdentifier("tab.\(tab.id)")
            .accessibilityLabel(tab.displayTitle)
            .accessibilityValue(tabAccessibilityValue(tab))
            .accessibilityHint(tab.isOpen ? "Select tab. Option-click to rename. More actions in the context menu." : "Reopen saved tab. Option-click to rename.")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(tab.pinnedURL.map { "Pinned URL: \($0.absoluteString)\nCurrent URL: \(tab.currentURL.absoluteString)\(tab.isOpen ? "" : "\nClick to reopen")" }
                  ?? tab.currentURL.absoluteString)
            .highPriorityGesture(tabClickGesture(tab))
            if tab.isOpen && hoveredTab == tab.id {
                Button { model.perform(.closeTab(tab.id)) } label: {
                    Image(systemName: "xmark").font(.caption)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(hoveredTab == tab.id ? 0.12 : 0.07),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                    .buttonStyle(SidebarButtonStyle())
                    .focused($focusedSidebarControl, equals: .close(tab.id))
                    .accessibilityIdentifier("tabClose.\(tab.id)")
                    .accessibilityLabel("Close \(tab.displayTitle)")
                    .help(tab.pinnedURL == nil ? "Close tab" : "Close page and keep pin")
            }
        }
        .padding(.leading, tab.pinnedURL == nil ? 8 : 0)
        .padding(.trailing, 8)
        .background(Color.primary.opacity(selected ? 0.08 : (hoveredTab == tab.id ? 0.04 : 0)))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(focused ? Color.primary.opacity(0.55) : .clear, lineWidth: 2)
                .allowsHitTesting(false)
        }
        .onHover { updateTabHover(tab.id, hovering: $0) }
        .background(draggingTab == tab.id ? Color(nsColor: .windowBackgroundColor) : .clear,
                    in: RoundedRectangle(cornerRadius: cornerRadius))
        .shadow(color: .black.opacity(draggingTab == tab.id ? 0.18 : 0), radius: 6, y: 3)
        .offset(previewOffset(tab.id))
        .opacity(draggingTab == tab.id ? 0 : 1)
        .zIndex(draggingTab == tab.id ? 1 : 0)
        .animation(draggingTab == tab.id || reduceMotion ? nil : .easeInOut(duration: 0.16), value: previewOffset(tab.id))
        .background(tabFrame(tab.id))
        .contextMenu { tabActions(tab) }
    }

    private func updateTabHover(_ id: UUID, hovering: Bool) {
        if hovering { hoveredTab = id }
        else if hoveredTab == id { hoveredTab = nil }
    }

    private func tabAccessibilityValue(_ tab: BrowserTab) -> String {
        let section = tab.isFavorite ? "Favorite" : "Pinned"
        let base = tab.pinnedURL == nil ? "Today" : "\(section), \(tab.isOpen ? "open" : "closed")"
        guard let page = model.webViews.pages[tab.id] else { return base }
        if page.isLoading { return base + ", loading" }
        if page.failure != nil { return base + ", load failed" }
        return base
    }

    @ViewBuilder
    private func tabActions(_ tab: BrowserTab) -> some View {
        Button("Open Tab in New Window") { model.perform(.openTabInNewWindow(tab.id)) }
        Button("Rename Tab…") { model.perform(.requestRename(tab.id)) }
        if !tab.isFavorite {
            Menu("Move to Space") {
                ForEach(model.coordinator.spaces) { space in
                    Button(space.name) { model.perform(.moveTab(tab.id, toSpace: space.id)) }
                        .disabled(space.id == tab.spaceID)
                }
            }
            .disabled(!model.canManageSpaces || model.coordinator.spaces.count <= 1)
            Menu("Move to Folder") {
                Button("Top Level") { _ = model.coordinator.moveTab(tab.id, toFolder: nil); model.save() }
                    .disabled(tab.folderID == nil)
                ForEach(model.coordinator.folders) { folder in
                    Button(folderPath(folder)) { _ = model.coordinator.moveTab(tab.id, toFolder: folder.id); model.save() }
                        .disabled(tab.folderID == folder.id)
                }
            }
        }
        Button("Move Up") { model.perform(.moveTabBy(tab.id, -1)) }
            .disabled(model.coordinator.tabStore.siblingIDs(of: tab).first == tab.id)
        Button("Move Down") { model.perform(.moveTabBy(tab.id, 1)) }
            .disabled(model.coordinator.tabStore.siblingIDs(of: tab).last == tab.id)
        Button(tab.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
            model.perform(.setFavorite(tab.id, !tab.isFavorite))
        }
        if !tab.isFavorite {
            Button(tab.pinnedURL == nil ? "Pin Tab" : "Unpin Tab") {
                model.perform(.setPinned(tab.id, tab.pinnedURL == nil))
            }
        }
        if tab.pinnedURL != nil {
            Button("Reset to Pinned URL") { model.perform(.resetPinnedTab(tab.id)) }
        }
        if model.webViews.pages[tab.id]?.isLoading == true {
            Button("Stop Loading") { model.webViews.stop(tab.id) }
        }
        Divider()
        Button("Close Tab") { model.perform(.closeTab(tab.id)) }
            .disabled(!tab.isOpen)
    }

    private var favoritesSection: some View {
        let count = model.favorites.count + (receivingFavorite ? 1 : 0)
        let height = max(SidebarReorderLayout.favoriteHeight,
                         CGFloat((count + 3) / 4) * SidebarReorderLayout.favoriteRowStride - 6)
        return ScrollView {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    ForEach(visibleFavorites) { tab in
                        let frame = favoriteDisplayFrame(tab.id, width: geometry.size.width)
                        favoriteTile(tab)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                            .animation(draggingTab == tab.id || reduceMotion ? nil : .easeInOut(duration: 0.16), value: frame)
                    }
                    if model.favorites.isEmpty {
                        Text("Favorites").font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).frame(height: SidebarReorderLayout.favoriteHeight)
                            .accessibilityIdentifier("sidebar.favorites.dropTarget")
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(height: height)
            .background(dropArea("favoriteContent"))
        }
        .frame(height: min(height, SidebarReorderLayout.favoriteRowStride * 3 - 6))
        .background {
            if draggingTab != nil && model.favorites.isEmpty {
                groupPanel(active: destinationSection(at: dragPoint) == .favorites, dashed: true)
            }
        }
        .accessibilityIdentifier("sidebar.favorites")
        .background(sectionFrame(favorites: true))
        .background(dropArea("favorites"))
    }

    private func favoriteDisplayFrame(_ id: UUID, width: CGFloat) -> CGRect {
        let original = model.favorites.map(\.id)
        var order = original
        if let draggingTab {
            if destinationSection(at: dragPoint) == .favorites,
               let dragLayout, dragLayout.grid {
                order = dragLayout.order(at: dragPoint)
            } else {
                order.removeAll { $0 == draggingTab }
            }
        }
        let bounds = CGRect(x: 0, y: 0, width: width, height: 0)
        if let index = order.firstIndex(of: id) {
            return SidebarReorderLayout.favoriteFrames(count: order.count, in: bounds)[index]
        }
        // Keep the source view and its gesture mounted until release/cancellation.
        let frames = SidebarReorderLayout.favoriteFrames(count: original.count, in: bounds)
        return original.firstIndex(of: id).map { frames[$0] } ?? .zero
    }

    private var visibleFavorites: [BrowserTab] {
        guard let content = dropAreas["favoriteContent"], let viewport = sectionFrames[true] else {
            return Array(model.favorites.prefix(12))
        }
        // Keep scrolling collections bounded, and retain the drag source even
        // when its preview leaves the viewport so its gesture can finish.
        let frames = SidebarReorderLayout.favoriteFrames(count: model.favorites.count, in: content)
        let visible = viewport.insetBy(dx: 0, dy: -SidebarReorderLayout.favoriteRowStride)
        return zip(model.favorites, frames).compactMap { tab, frame in
            tab.id == draggingTab || frame.intersects(visible) ? tab : nil
        }
    }

    /// Page-level loading feedback stays separate from static sidebar artwork.
    @ViewBuilder
    private var pageLoadingLine: some View {
        if let page = model.activePage, page.isLoading {
            let progress = min(max(page.progress, 0), 1)
            GeometryReader { geometry in
                Rectangle().fill(Color.accentColor)
                    .frame(width: geometry.size.width * progress)
            }
            .frame(height: 2)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Page loading")
            .accessibilityValue("\(Int(progress * 100)) percent")
            .accessibilityIdentifier("browser.loading")
        }
    }

    private func favoriteTile(_ tab: BrowserTab) -> some View {
        let name = tab.customTitle ?? tab.pinnedTitle ?? tab.pinnedURL?.host ?? tab.title
        let selected = model.coordinator.activeTabID == tab.id
        let tint = favoriteTint(tab)
        let border = (selected ? tint : nil)?.opacity(contrast == .increased ? 0.80 : 0.55)
            ?? Color.primary.opacity(contrast == .increased ? 0.30 : 0.07)
        return Button { model.perform(.selectTab(tab.id)) } label: {
            SiteIcon(url: tab.pinnedURL ?? tab.currentURL, store: model.webViews.favicons,
                     size: 18, monogram: String(name.prefix(1)).uppercased())
            .foregroundStyle(tab.isOpen ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .frame(height: SidebarReorderLayout.favoriteHeight)
            .background {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.primary.opacity(selected ? 0.12 : (hoveredTab == tab.id ? 0.08 : 0.04)))
                if selected, let tint {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(tint.opacity(colorScheme == .dark ? 0.26 : 0.20))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(border, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .focused($focusedSidebarControl, equals: .favorite(tab.id))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(focusedSidebarControl == .favorite(tab.id) ? Color.primary.opacity(0.55) : .clear, lineWidth: 2)
                .allowsHitTesting(false)
        }
        .onHover { updateTabHover(tab.id, hovering: $0) }
        .accessibilityIdentifier("favorite.\(tab.id)")
        .accessibilityLabel(name)
        .accessibilityValue(tabAccessibilityValue(tab))
        .accessibilityHint(tab.isOpen ? "Select favorite. Option-click to rename. More actions in the context menu." : "Reopen saved favorite. Option-click to rename.")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("\(name)\n\((tab.pinnedURL ?? tab.currentURL).absoluteString)")
        .highPriorityGesture(tabClickGesture(tab))
        .opacity(draggingTab == tab.id ? 0 : 1)
        .zIndex(draggingTab == tab.id ? 1 : 0)
        .contextMenu { tabActions(tab) }
    }

    private func favoriteTint(_ tab: BrowserTab) -> Color? {
        guard let color = model.webViews.favicons.color(for: tab.pinnedURL ?? tab.currentURL) else { return nil }
        let iconColor = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        iconColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: hue, saturation: min(saturation * 0.55, 0.50),
                     brightness: colorScheme == .dark ? 0.72 : 0.64)
    }

    /// The title selects/reopens a pin. Its icon is interactive only for reset
    /// when a live page has navigated away from the saved address.
    private struct PinnedTabIcon: View {
        let tab: BrowserTab
        let favicons: FaviconStore
        let page: BrowserPage?
        let reset: () -> Void
        var requestsArtwork = true
        @State private var hovered = false
        @FocusState private var focused: Bool

        private var canReset: Bool { tab.isOpen && tab.hasNavigatedFromPin }

        var body: some View {
            Button(action: reset) {
                Group {
                    if canReset && (hovered || focused) {
                        Image(systemName: "arrow.uturn.backward")
                    } else {
                        TabArtwork(tab: tab, store: favicons, page: page, size: 16, fallback: "pin",
                                   requestsArtwork: requestsArtwork)
                    }
                }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tab.isOpen ? .primary : .secondary)
                    .frame(width: PinnedIsland.height, height: PinnedIsland.height)
                    .background(Color.primary.opacity(canReset && (hovered || focused) ? 0.16 : 0),
                                in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
            }
            .buttonStyle(SidebarButtonStyle())
            .disabled(!canReset)
            .focused($focused)
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(focused ? Color.primary.opacity(0.55) : .clear, lineWidth: 2)
                    .allowsHitTesting(false)
            }
            .onHover { hovered = $0 }
            .accessibilityIdentifier("\(canReset ? "pinReset" : "pinSelect").\(tab.id)")
            .accessibilityLabel(canReset ? "Reset \(tab.customTitle ?? tab.pinnedTitle ?? tab.title) to pinned URL" : "Saved page icon")
            .help(canReset ? "Reset pinned tab" : "Saved page")
        }
    }

    /// Disabled neighbor pages and unavailable pin-reset actions stay visually
    /// unchanged. PlainButtonStyle would dim them, then flash on selection.
    private struct SidebarButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
        }
    }

    /// Artwork is independent of loading state; unloaded pins never allocate
    /// a web view or start navigation just to display an icon.
    private struct TabArtwork: View {
        let tab: BrowserTab
        let store: FaviconStore
        let page: BrowserPage?
        let size: CGFloat
        var fallback = "globe"
        var monogram: String?
        var requestsArtwork = true

        var body: some View {
            SiteIcon(url: tab.pinnedURL ?? tab.currentURL, store: store, size: size,
                     fallback: fallback, monogram: monogram, requestsArtwork: requestsArtwork)
            .frame(width: size, height: size)
            // The parent button supplies the accessible name and status.
            .accessibilityHidden(true)
        }
    }

    private struct SiteIcon: View {
        let url: URL
        let store: FaviconStore
        let size: CGFloat
        var fallback = "globe"
        var monogram: String?
        var requestsArtwork = true

        var body: some View {
            Group {
                if let image = store.image(for: url) {
                    Image(nsImage: image).resizable().scaledToFit()
                } else if let monogram {
                    Text(monogram).font(.system(size: size - 3, weight: .semibold))
                } else {
                    Image(systemName: fallback)
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
            .task(id: requestsArtwork ? url : nil) {
                if requestsArtwork { store.request(url) }
            }
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
        let header = HStack(spacing: 4) {
            // Neither disclosure nor title waits for a possible second click.
            Button { toggleFolder(folder) } label: {
                FolderIcon(isOpen: isFolderOpen(folder), themeColor: folderTheme(folder))
                    .frame(width: 19, height: 20)
                    .animation(folderExpansionAnimation, value: isFolderOpen(folder))
                    .frame(width: PinnedIsland.height, height: PinnedIsland.height)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }
            .buttonStyle(SidebarButtonStyle())
            .focused($focusedSidebarControl, equals: .folderToggle(folder.id))
            .accessibilityIdentifier("folderToggle.\(folder.id)")
            .accessibilityLabel("\(isFolderOpen(folder) ? "Collapse" : "Expand") \(folder.name)")
            .help("Click to expand or collapse. Option-click to rename.")
            .highPriorityGesture(folderClickGesture(folder))

            Button { toggleFolder(folder) } label: {
                HStack {
                    Text(folder.name).lineLimit(1)
                    Spacer(minLength: 0)
                }
                // Match the disclosure's full header. A shorter title
                // puts its top-edge drag target inside the folder retention band.
                .frame(height: PinnedIsland.height).contentShape(Rectangle())
            }
            .buttonStyle(SidebarButtonStyle())
            .focused($focusedSidebarControl, equals: .folder(folder.id))
            .accessibilityIdentifier("folder.\(folder.id)")
            .accessibilityLabel(folder.name)
            .accessibilityValue(isFolderOpen(folder) ? "Expanded" : "Collapsed")
            .accessibilityHint("Click to expand or collapse. Option-click to rename.")
            .highPriorityGesture(folderClickGesture(folder))
        }
        .padding(.trailing, 8)
        return header
        .help(folderPath(folder))
        // The anchored group panel owns the hover fill, including when closed.
        // A second header island leaves darker, mismatched corners over it.
        .overlay {
            RoundedRectangle(cornerRadius: PinnedIsland.cornerRadius)
                .strokeBorder(focusedSidebarControl == .folder(folder.id) || focusedSidebarControl == .folderToggle(folder.id) ? Color.primary.opacity(0.55) : .clear, lineWidth: 2)
                .allowsHitTesting(false)
        }
        .onHover { hovering in
            if hovering { hoveredFolder = folder.id }
            else if hoveredFolder == folder.id { hoveredFolder = nil }
        }
        .anchorPreference(key: FolderBoundaries.self, value: .bounds) {
            [.header(folder.id): $0]
        }
        .background(folderHitFrame(folder.id))
        .offset(previewOffset(folder.id))
        .opacity(draggingTab == folder.id ? 0 : 1)
        .animation(draggingTab == nil || reduceMotion ? nil : .easeInOut(duration: 0.16), value: previewOffset(folder.id))
        .background(tabFrame(folder.id))
        .contextMenu {
            Button("New Subfolder…") { editFolder(nil, parent: folder.id) }
                .disabled(!model.coordinator.tabStore.canCreateFolder(in: folder.id, spaceID: folder.spaceID))
            Button("Rename Folder…") { editFolder(folder, parent: folder.parentID) }
            Menu("Move to Space") {
                ForEach(model.coordinator.spaces) { space in
                    Button(space.name) {
                        endDrag()
                        hoveredFolder = nil
                        focusedSidebarControl = nil
                        model.perform(.moveFolder(folder.id, toSpace: space.id))
                    }
                    .disabled(space.id == folder.spaceID)
                }
            }
            .disabled(!model.canManageSpaces || model.coordinator.spaces.count <= 1)
            Menu("Move Folder") {
                Button("Top Level") { _ = model.coordinator.moveFolder(folder.id, to: nil); model.save() }
                    .disabled(folder.parentID == nil)
                ForEach(model.coordinator.folders) { parent in
                    Button(folderPath(parent)) { _ = model.coordinator.moveFolder(folder.id, to: parent.id); model.save() }
                        .disabled(!model.coordinator.tabStore.canMoveFolder(folder.id, to: parent.id) || parent.id == folder.parentID)
                }
            }
            Divider()
            Button("Delete Folder", role: .destructive) {
                endDrag()
                hoveredFolder = nil
                focusedSidebarControl = nil
                model.perform(.deleteFolder(folder.id))
            }
            .help("Delete this folder, all subfolders, and all their tabs")
        }
    }

    private func folderTheme(_ folder: BrowserFolder) -> BrowserSpace.Color {
        guard model.preferences.spaceThemes else { return .gray }
        // Neighboring Space pages and drag previews retain their own theme.
        return model.coordinator.spaces.first { $0.id == folder.spaceID }?.color ?? .gray
    }

    private enum SidebarFrame: Hashable {
        case item(UUID), folderHeader(UUID), section(Bool), dropArea(String)
    }

    private struct SidebarFrames: PreferenceKey {
        static let defaultValue: [SidebarFrame: CGRect] = [:]
        static func reduce(value: inout [SidebarFrame: CGRect], nextValue: () -> [SidebarFrame: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { _, new in new })
        }
    }

    private func folderHitFrame(_ id: UUID) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: SidebarFrames.self,
                value: [.folderHeader(id): geometry.frame(in: .named("sidebarReordering"))])
        }.allowsHitTesting(false)
    }

    private func tabFrame(_ id: UUID) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: SidebarFrames.self,
                                   value: [.item(id): geometry.frame(in: .named("sidebarReordering"))])
        }
        .allowsHitTesting(false)
    }

    private func sectionFrame(favorites: Bool) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: SidebarFrames.self,
                                   value: [.section(favorites): geometry.frame(in: .named("sidebarReordering"))])
        }
        .allowsHitTesting(false)
    }

    private func itemFrame(_ id: UUID) -> CGRect? {
        if let index = model.favorites.firstIndex(where: { $0.id == id }),
           let bounds = dropAreas["favoriteContent"] {
            return SidebarReorderLayout.favoriteFrames(
                count: model.favorites.count + (receivingFavorite ? 1 : 0), in: bounds)[index]
        }
        return frozenFrames[id] ?? tabFrames[id]
    }

    private func beginDrag(_ tab: BrowserTab) {
        guard let frame = itemFrame(tab.id) else { return }
        model.sidebarInteractionInProgress = true
        BrowserHaptics.pickupOrDrop(enabled: model.preferences.haptics)
        frozenFrames = tabFrames
        dragSourceFrame = frame
        dropFolder = section(of: tab) == .pinned ? tab.folderID : nil
        updateFolderDropSlot(dropFolder)
        refreshDragLayout(for: tab, at: dragPoint)
    }

    private func endDrag() {
        model.sidebarInteractionInProgress = false
        dragFeedbackTarget = nil
        pendingFolder = nil
        dropFolder = nil
        previousDragPoint = nil
        insertionContainer = nil
        insertionSiblings = []
        insertionIndex = nil
        reservedFolderSlot = nil
        revealDropSections = false
        dragLayout = nil
        dragTranslation = .zero
        dragSourceFrame = .zero
        frozenFrames = [:]
    }

    private func refreshCurrentDrag() {
        guard let id = draggingTab else { return }
        if let tab = model.coordinator.tabStore.tab(id: id) {
            refreshDragLayout(for: tab, at: dragPoint)
        } else if let folder = model.coordinator.folders.first(where: { $0.id == id }) {
            refreshFolderDragLayout(folder, at: dragPoint)
        }
    }

    private func refreshFolderDragLayout(_ folder: BrowserFolder, at point: CGPoint) {
        guard destinationSection(at: point) == .pinned else { dragLayout = nil; return }
        let parent = dropFolder
        guard model.coordinator.tabStore.canMoveFolder(folder.id, to: parent) else { dragLayout = nil; return }
        var slots = destinationSlots(in: .pinned, folderID: parent)
        let bounds = destinationBounds(in: .pinned, folderID: parent, slots: slots)
        let foreign = !slots.contains(where: { $0.id == folder.id })
        if foreign {
            let preceding = slots.last?.frame ?? parent.flatMap { folderChildHeaderFrame($0) } ?? dropAreas["pinned"]
            slots.append(.init(id: folder.id, frame: SidebarReorderLayout.placeholderFrame(
                after: preceding, bounds: bounds, grid: false,
                size: CGSize(width: bounds.width, height: dragSourceFrame.height))))
        }
        guard bounds.width > 0, bounds.height > 0 else { dragLayout = nil; return }
        installDragLayout(source: folder.id, slots: slots, bounds: bounds, grid: false, foreign: foreign,
                          container: DragContainer(section: .pinned, parent: parent), at: point)
    }

    private func refreshDragLayout(for tab: BrowserTab, at point: CGPoint) {
        let destination = destinationSection(at: point) ?? section(of: tab)
        let folderID = destination == .pinned ? dropFolder : nil
        var slots = destinationSlots(in: destination, folderID: folderID)
        let bounds = destinationBounds(in: destination, folderID: folderID, slots: slots)
        let foreign = !slots.contains(where: { $0.id == tab.id })
        if foreign {
            if destination == .favorites {
                let content = dropAreas["favoriteContent"] ?? bounds.insetBy(dx: 6, dy: 6)
                if let frame = SidebarReorderLayout.favoriteFrames(count: slots.count + 1, in: content).last {
                    slots.append(.init(id: tab.id, frame: frame))
                }
            } else {
                let size = CGSize(width: bounds.width, height: destination == .pinned ? 34 : 32)
                let preceding = slots.last?.frame ?? (destination == .pinned
                    ? (folderID.flatMap { folderChildHeaderFrame($0) } ?? dropAreas["pinned"]) : nil)
                slots.append(.init(id: tab.id, frame: SidebarReorderLayout.placeholderFrame(
                    after: preceding, bounds: bounds, grid: false, size: size)))
            }
        }
        guard bounds.width > 0, bounds.height > 0, slots.contains(where: { $0.id == tab.id }) else { dragLayout = nil; return }
        installDragLayout(source: tab.id, slots: slots, bounds: bounds, grid: destination == .favorites,
                          foreign: foreign, container: DragContainer(section: destination, parent: folderID), at: point)
    }

    private func installDragLayout(source: UUID, slots: [SidebarReorderLayout.Slot], bounds: CGRect,
                                   grid: Bool, foreign: Bool, container: DragContainer, at point: CGPoint) {
        let siblings = slots.filter { $0.id != source }.map(\.id)
        let retained = insertionContainer == container && insertionSiblings == siblings ? insertionIndex : nil
        let layout = SidebarReorderLayout(source: source, slots: slots, bounds: bounds, grid: grid,
                                          foreign: foreign, retainedIndex: retained)
        dragLayout = layout
        let hitPoint = point
        guard bounds.contains(hitPoint) else { return }
        insertionContainer = container
        insertionSiblings = siblings
        insertionIndex = layout.order(at: hitPoint).firstIndex(of: source)
        let feedback = DragFeedbackTarget(container: container, index: insertionIndex)
        if let previous = dragFeedbackTarget, previous != feedback { BrowserHaptics.alignment(enabled: model.preferences.haptics) }
        dragFeedbackTarget = feedback
    }

    private func destinationSlots(in destination: TabStore.Section, folderID: UUID?) -> [SidebarReorderLayout.Slot] {
        let ids: [UUID]
        switch destination {
        case .favorites:
            guard let content = dropAreas["favoriteContent"] else { return [] }
            let frames = SidebarReorderLayout.favoriteFrames(
                count: model.favorites.count + (receivingFavorite ? 1 : 0), in: content)
            return zip(model.favorites, frames).map { .init(id: $0.0.id, frame: $0.1) }
        case .regular:
            ids = model.todayTabs.map(\.id)
        case .pinned:
            if let folderID, let folder = model.coordinator.folders.first(where: { $0.id == folderID }),
               !folderPreview(folder).showsContents {
                // Hidden children never become phantom ordering targets from a
                // previous geometry snapshot. A closed folder accepts append.
                return []
            }
            ids = model.coordinator.tabStore.pinnedItems(in: model.coordinator.activeSpaceID, parentID: folderID).map(\.id)
        }
        return ids.compactMap { id in
            guard let header = itemFrame(id) else { return nil }
            var block = header
            if destination == .pinned, let group = folderGroupFrame(id) {
                block = group
            }
            return SidebarReorderLayout.Slot(id: id, frame: block, hitFrame: header)
        }
    }

    private func folderChildHeaderFrame(_ id: UUID) -> CGRect? {
        itemFrame(id).map { header in
            CGRect(x: header.minX + 12, y: header.minY,
                   width: max(1, header.width - 16), height: header.height)
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
            guard let viewport = sectionFrames[false], let divider = dropAreas["divider"] else { return .null }
            if let folderID, let group = folderGroupFrame(folderID) {
                return group.intersection(viewport)
            }
            return CGRect(x: viewport.minX, y: viewport.minY, width: viewport.width,
                          height: max(0, min(divider.maxY, viewport.maxY) - viewport.minY))
        }
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
        let visible = Set(pinnedOutline.filter(\.isFolder).map(\.id))
        let expanded = model.coordinator.folders.filter {
            visible.contains($0.id) && folderPreview($0).showsPanel && validFolderTarget($0.id)
        }
        let enclosing = expanded.filter { folder in
            guard let header = folderHitFrames[folder.id], let baseline = itemFrame(folder.id),
                  let group = folderGroupFrame(folder.id) else { return false }
            let displayed = group.offsetBy(dx: header.minX - baseline.minX, dy: header.minY - baseline.minY)
            let retaining = dropFolder == folder.id
            // A continuous corridor connects header, children, inter-row gaps
            // and insertion space. The old 3-point seam collapsed the folder
            // just as the pointer crossed from its header into its children.
            let top = retaining ? header.minY + 3 : header.maxY
            // Keep the same leading escape lane for entry and retention.
            // It must reliably switch to the parent container rather than
            // leaving an already-open folder sticky at this edge.
            return point.x >= header.minX + 12
                && point.x <= displayed.maxX
                && point.y >= top && point.y <= displayed.maxY + (retaining ? 4 : 0)
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
        // Retain the current header through small edge movements.
        for id in [pendingFolder, dropFolder].compactMap({ $0 }) {
            if folderHeaderAccepts(point, folderID: id, retaining: true) { return id }
        }
        let folders = model.coordinator.folders.compactMap { folder -> (UUID, CGRect)? in
            guard folderHeaderAccepts(point, folderID: folder.id, retaining: false),
                  let frame = folderHitFrames[folder.id] else { return nil }
            return (folder.id, frame)
        }
        guard let match = folders.min(by: { $0.1.height < $1.1.height }) else { return nil }
        return match.0
    }

    private func folderHeaderAccepts(_ point: CGPoint, folderID: UUID, retaining: Bool) -> Bool {
        guard validFolderTarget(folderID), pinnedOutline.contains(where: { $0.id == folderID && $0.isFolder }),
              let frame = folderHitFrames[folderID] else { return false }
        guard sectionFrames[false]?.contains(point) == true else { return false }
        // The leading gutter always permits lifting an item out one level.
        return SidebarFolderPreview.acceptsHeader(point, header: frame, retaining: retaining)
    }

    private func validFolderTarget(_ id: UUID) -> Bool {
        guard let source = draggingTab, model.coordinator.folders.contains(where: { $0.id == source }) else { return true }
        return model.coordinator.tabStore.canMoveFolder(source, to: id)
    }

    private func nextFolderOnDownwardExit(at point: CGPoint, previous: CGPoint) -> UUID? {
        let outline = pinnedOutline
        guard let current = dropFolder,
              reservedFolderSlot == current,
              let header = folderHitFrames[current], let baseline = itemFrame(current),
              let group = folderGroupFrame(current),
              let index = outline.firstIndex(where: { $0.id == current }) else { return nil }
        let currentDepth = outline[index].depth
        // Walk beyond this branch, rather than mistaking its last child for
        // the next destination. Do not hop across an intervening tab row.
        guard let next = outline.dropFirst(index + 1).first(where: { $0.depth <= currentDepth }),
              next.isFolder, validFolderTarget(next.id), let nextHeader = folderHitFrames[next.id] else { return nil }
        let displayedGroup = group.offsetBy(dx: header.minX - baseline.minX, dy: header.minY - baseline.minY)
        guard SidebarFolderHandoff.acceptsDownwardEntry(from: previous, to: point,
            departingBounds: displayedGroup, nextHeader: nextHeader) else { return nil }
        return next.id
    }

    private func updateFolderHover(at point: CGPoint) {
        defer { previousDragPoint = point }
        guard destinationSection(at: point) == .pinned else {
            pendingFolder = nil
            dropFolder = nil
            updateFolderDropSlot(nil)
            return
        }
        let hitPoint = point
        if let previousDragPoint,
           let next = nextFolderOnDownwardExit(at: hitPoint, previous: previousDragPoint) {
            // Replace one temporary row with another. There is no hover-opened
            // tree to collapse, and targeting follows the visible coordinates.
            settleFolderHover(next)
            return
        }
        let target = nestTarget(at: hitPoint)
        let container = target ?? containerFolder(at: hitPoint)
        // A nested receiving row belongs to its current folder even if an
        // ancestor's stale panel measurement also contains it. Explicit
        // headers and deeper containers still take priority; the leading
        // gutter and upper edge remain available for moving out one level.
        if target == nil, retainsFolderNearBoundary(at: hitPoint, enclosing: container) {
            pendingFolder = nil
            return
        }
        if container == dropFolder {
            pendingFolder = target
            return
        }
        settleFolderHover(container)
    }

    private func settleFolderHover(_ target: UUID?) {
        pendingFolder = target
        dropFolder = target
        updateFolderDropSlot(target)
    }

    private func retainsFolderNearBoundary(at point: CGPoint, enclosing: UUID?) -> Bool {
        guard let current = dropFolder, let header = folderHitFrames[current],
              let folder = model.coordinator.folders.first(where: { $0.id == current }),
              let baseline = itemFrame(current), let group = folderGroupFrame(current) else { return false }
        let displayed = group.offsetBy(dx: header.minX - baseline.minX, dy: header.minY - baseline.minY)
        let enclosingDepth = enclosing.flatMap { id in
            model.coordinator.folders.first(where: { $0.id == id }).map { depth(of: $0) }
        }
        return SidebarFolderPreview.retainsPanel(point, header: header, panel: displayed,
            currentDepth: depth(of: folder), enclosingDepth: enclosingDepth)
    }

    private func updateFolderDropSlot(_ target: UUID?) {
        // Reordering within this folder already has the source row as its slot.
        // A second trailing slot adds a spurious blank row beneath the children.
        let slot = target.flatMap { needsPinInsertionSpace(in: $0) ? $0 : nil }
        guard reservedFolderSlot != slot else { return }
        withAnimation(folderDragAnimation) {
            reservedFolderSlot = slot
        }
    }

    private func folderReorderGesture(_ folder: BrowserFolder) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("sidebarReordering"))
            .updating($draggingTab) { _, state, _ in state = folder.id }
            .onChanged { value in
                guard model.coordinator.commandBar == nil, model.renamingTabID == nil else { return }
                dragPoint = value.location
                if dragSourceFrame == .zero {
                    guard let frame = itemFrame(folder.id) else { return }
                    model.sidebarInteractionInProgress = true
                    BrowserHaptics.pickupOrDrop(enabled: model.preferences.haptics)
                    frozenFrames = tabFrames
                    dragSourceFrame = frame
                    dropFolder = folder.parentID
                    updateFolderDropSlot(dropFolder)
                }
                revealDropSections = true
                dragTranslation = CGSize(width: 0, height: value.translation.height)
                updateFolderHover(at: value.location)
                refreshFolderDragLayout(folder, at: value.location)
            }
            .onEnded { value in
                defer { endDrag() }
                guard model.coordinator.commandBar == nil, model.renamingTabID == nil else { return }
                dragPoint = value.location
                updateFolderHover(at: value.location)
                guard destinationSection(at: value.location) == .pinned else { return }
                refreshFolderDragLayout(folder, at: value.location)
                let parent = dropFolder
                let insertion = dragLayout?.insertion(at: value.location)
                guard dragLayout != nil, insertion != nil || parent != folder.parentID else { return }
                if model.coordinator.placeFolder(folder.id, in: parent, before: insertion?.before) {
                    model.save()
                    BrowserHaptics.pickupOrDrop(enabled: model.preferences.haptics)
                }
            }
    }

    private func toggleFolder(_ folder: BrowserFolder) {
        #if DEBUG
        if model.isTesting { folderToggleActionCount += 1 }
        #endif
        let affected = SidebarFolderBounce.affectedFolders(toggling: folder.id,
            in: model.coordinator.folders, hasChildren: folderHasChildren(folder.id, in: folder.spaceID))
        // A child changes its ancestors' bounds too. Give the whole affected
        // branch one pulse; empty toggles only animate the folder icon.
        folderBounceEvent = reduceMotion || draggingTab != nil || affected.isEmpty
            ? nil : FolderBounceEvent(folders: affected)
        withAnimation(folderExpansionAnimation) {
            model.coordinator.toggleFolder(folder.id)
        }
        model.save()
    }

    private func tabClickGesture(_ tab: BrowserTab) -> some Gesture {
        // Only Option-click competes with the button's immediate action. There
        // is no double-click timer; a drag takes priority over renaming.
        reorderGesture(tab).exclusively(before:
            TapGesture().modifiers(.option).onEnded { model.perform(.requestRename(tab.id)) }
        )
    }

    private func folderClickGesture(_ folder: BrowserFolder) -> some Gesture {
        folderReorderGesture(folder).exclusively(before:
            TapGesture().modifiers(.option).onEnded { editFolder(folder, parent: folder.parentID) }
        )
    }

    private func reorderGesture(_ tab: BrowserTab) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("sidebarReordering"))
            .updating($draggingTab) { _, state, _ in state = tab.id }
            .onChanged { value in
                guard model.coordinator.commandBar == nil, model.renamingTabID == nil else { return }
                dragPoint = value.location
                if dragSourceFrame == .zero { beginDrag(tab) }
                revealDropSections = true
                dragTranslation = CGSize(width: tab.isFavorite ? value.translation.width : 0,
                                         height: value.translation.height)
                updateFolderHover(at: value.location)
                refreshDragLayout(for: tab, at: value.location)
            }
            .onEnded { value in
                defer { endDrag() }
                guard model.coordinator.commandBar == nil, model.renamingTabID == nil else { return }
                dragPoint = value.location
                updateFolderHover(at: value.location)
                guard let destination = destinationSection(at: value.location) else { return }
                refreshDragLayout(for: tab, at: value.location)
                let folderID = destination == .pinned ? dropFolder : nil
                if let drop = dragLayout?.insertion(at: value.location) {
                    if model.placeTab(tab.id, in: destination, folderID: folderID, before: drop.before) {
                        BrowserHaptics.pickupOrDrop(enabled: model.preferences.haptics)
                    }
                } else if destination != section(of: tab) || folderID != tab.folderID {
                    if model.placeTab(tab.id, in: destination, folderID: folderID, before: nil) {
                        BrowserHaptics.pickupOrDrop(enabled: model.preferences.haptics)
                    }
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
            // Preview the destination, not the source tab's persisted section.
            // Membership still changes only after a successful drop.
            let destination = destinationSection(at: dragPoint)
            let overFavorites = destination == .favorites
            let rowBounds = dragRowBounds(at: dragPoint)
            let favoriteBounds = dropAreas["favoriteContent"] ?? rowBounds.insetBy(dx: 6, dy: 0)
            let order = dragLayout?.grid == true ? dragLayout?.order(at: dragPoint) ?? [] : []
            let tileFrames = SidebarReorderLayout.favoriteFrames(count: max(1, order.count), in: favoriteBounds)
            let tileWidth = order.firstIndex(of: draggingTab).map { tileFrames[$0].width } ?? tileFrames.first?.width ?? 54
            let rowHeight: CGFloat = destination == .pinned ? PinnedIsland.height : 32
            let cornerRadius: CGFloat = overFavorites ? 9 : (destination == .pinned ? PinnedIsland.cornerRadius : 7)
            let name = tab.customTitle ?? tab.pinnedTitle ?? tab.pinnedURL?.host ?? tab.title
            HStack(spacing: 8) {
                TabArtwork(tab: tab, store: model.webViews.favicons, page: model.webViews.pages[tab.id],
                           size: overFavorites ? 18 : 16,
                           monogram: overFavorites ? String(name.prefix(1)).uppercased() : nil)
                if !overFavorites {
                    Text(tab.displayTitle).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
            }
                .font(.callout).lineLimit(1)
                .padding(.horizontal, 8)
                .frame(width: overFavorites ? tileWidth : rowBounds.width,
                       height: overFavorites ? SidebarReorderLayout.favoriteHeight : rowHeight)
                .background {
                    if overFavorites, model.coordinator.activeTabID == tab.id, let tint = favoriteTint(tab) {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(tint.opacity(colorScheme == .dark ? 0.26 : 0.20))
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay {
                    if overFavorites, model.coordinator.activeTabID == tab.id, let tint = favoriteTint(tab) {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(tint.opacity(contrast == .increased ? 0.80 : 0.55), lineWidth: 1)
                    }
                }
                .shadow(radius: 5, y: 2)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: overFavorites)
                .animation(folderDragAnimation, value: overFavorites ? tileWidth : rowBounds.width)
                .offset(x: overFavorites ? 0 : rowBounds.midX)
                .animation(folderDragAnimation, value: overFavorites ? 0 : rowBounds.midX)
                // Keep the square under the pointer in the grid, and align
                // the expanded row with the list. Pointer movement never lags
                // behind a shape-transition animation.
                .position(x: overFavorites ? dragPoint.x : 0,
                          y: dragSourceFrame.midY + dragTranslation.height)
                .allowsHitTesting(false).accessibilityHidden(true)
        } else if let draggingTab, let folder = model.coordinator.folders.first(where: { $0.id == draggingTab }) {
            let bounds = dragRowBounds(at: dragPoint)
            HStack(spacing: 4) {
                FolderIcon(isOpen: false, themeColor: folderTheme(folder))
                    .frame(width: 19, height: 20)
                    .frame(width: PinnedIsland.height, height: PinnedIsland.height)
                Text(folder.name).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(.callout).padding(.trailing, 8)
            .frame(width: bounds.width, height: dragSourceFrame.height)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: PinnedIsland.cornerRadius))
            .shadow(radius: 5, y: 2)
            .animation(folderDragAnimation, value: bounds.width)
            .offset(x: bounds.midX)
            .animation(folderDragAnimation, value: bounds.midX)
            .position(x: 0, y: dragSourceFrame.midY + dragTranslation.height)
            .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private func dragRowBounds(at point: CGPoint) -> CGRect {
        let bounds = sectionFrames[false] ?? dropAreas["favorites"] ?? dragSourceFrame
        guard destinationSection(at: point) == .pinned,
              let parent = dropFolder,
              let header = itemFrame(parent) else { return bounds }
        // Match a child's inset inside this folder, including nested outlines.
        return CGRect(x: header.minX + 12, y: bounds.minY,
                      width: max(1, header.width - 16), height: bounds.height)
    }

    private func dropArea(_ key: String) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: SidebarFrames.self, value: [.dropArea(key): geometry.frame(in: .named("sidebarReordering"))])
        }.allowsHitTesting(false)
    }

    private func section(of tab: BrowserTab) -> TabStore.Section {
        tab.isFavorite ? .favorites : (tab.pinnedURL == nil ? .regular : .pinned)
    }

    private func needsPinInsertionSpace(in parent: UUID?) -> Bool {
        guard let source = draggingTab, destinationSection(at: dragPoint) == .pinned,
              dropFolder == parent else { return false }
        // An incoming item gets one temporary drop row, including in an empty
        // folder. Clicking an empty folder alone never reserves this space.
        if let tab = model.coordinator.tabStore.tab(id: source) {
            return section(of: tab) != .pinned || tab.folderID != parent
        }
        if let folder = model.coordinator.folders.first(where: { $0.id == source }) {
            return folder.parentID != parent
        }
        return false
    }

    private func destinationSection(at point: CGPoint) -> TabStore.Section? {
        if dropAreas["favorites"]?.contains(point) == true { return .favorites }
        guard let viewport = sectionFrames[false], viewport.contains(point),
              let regular = dropAreas["regular"] else { return nil }
        return point.y >= regular.minY ? .regular : .pinned
    }

    private func groupPanel(active: Bool, dashed: Bool = false, isFolder: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: isFolder ? PinnedIsland.cornerRadius : 12)
            .fill(Color.primary.opacity(active ? 0.10 : (isFolder ? 0.04 : 0.045)))
            .overlay {
                // Ordinary folder hover uses the same clean fill as a tab.
                // Borders are reserved for actual drag destinations.
                if !isFolder || active {
                    RoundedRectangle(cornerRadius: isFolder ? PinnedIsland.cornerRadius : 12)
                        .strokeBorder(Color.primary.opacity(active ? 0.28 : 0.14),
                                      style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: dashed ? [3, 2] : []))
                }
            }
            .animation(folderDragAnimation, value: active)
            .allowsHitTesting(false).accessibilityHidden(true)
    }

    private func refreshFolderPanelHover() {
        var groups: Set<UUID> = []
        if sidebarVisible, let point = sidebarPointer.location,
           sectionFrames[false]?.contains(point) == true {
            for folder in model.coordinator.folders where folderPreview(folder).showsPanel {
                if folderGroupFrame(folder.id)?.contains(point) == true {
                    groups.insert(folder.id)
                }
            }
        }
        if groups != hoveredFolderGroups { hoveredFolderGroups = groups }
    }

    private func folderGroupFrame(_ id: UUID) -> CGRect? {
        guard let header = itemFrame(id),
              let folder = model.coordinator.folders.first(where: { $0.id == id }) else { return nil }
        let preview = folderPreview(folder)
        // The slot is usable immediately, including the frame before SwiftUI
        // publishes its first measurement after opening a closed folder.
        let minimumBottom = header.maxY + (preview.showsDropSlot ? SidebarFolderPreview.dropSlotHeight + 4 : 0)
        let bottom = preview.showsPanel ? max(minimumBottom, dropAreas["folderEnd.\(id)"]?.maxY ?? header.maxY) : header.maxY
        return CGRect(x: header.minX, y: header.minY, width: header.width,
                      height: max(header.height, bottom - header.minY))
    }

    private func isDropAncestor(_ id: UUID) -> Bool {
        var current = dropFolder ?? pendingFolder
        var seen: Set<UUID> = []
        while let folder = current, seen.insert(folder).inserted {
            if folder == id { return true }
            current = model.coordinator.folders.first(where: { $0.id == folder })?.parentID
        }
        return false
    }

    private enum FolderBoundary: Hashable {
        case header(UUID), end(UUID)
    }

    private struct FolderBoundaries: PreferenceKey {
        static let defaultValue: [FolderBoundary: Anchor<CGRect>] = [:]
        static func reduce(value: inout [FolderBoundary: Anchor<CGRect>],
                           nextValue: () -> [FolderBoundary: Anchor<CGRect>]) {
            value.merge(nextValue(), uniquingKeysWith: { _, new in new })
        }
    }

    private struct FolderPanel: Identifiable {
        let id: UUID
        let frame: CGRect
    }

    private struct FolderBounceDrawing: ViewModifier {
        @Environment(\.folderBounceDisplacement) private var displacement
        let frame: CGRect
        let affected: Bool

        func body(content: Content) -> some View {
            content
                .frame(width: frame.width, height: frame.height + (affected ? displacement : 0))
                .offset(x: frame.minX, y: frame.minY)
        }
    }

    private func pinnedGroupBackgrounds(anchors: [FolderBoundary: Anchor<CGRect>]) -> some View {
        GeometryReader { geometry in
            let origin = geometry.frame(in: .named("sidebarReordering")).origin
            let visible = Set(pinnedOutline.filter(\.isFolder).map(\.id))
            let panels = model.coordinator.folders.compactMap { folder -> FolderPanel? in
                guard visible.contains(folder.id), folder.id != draggingTab,
                      let anchor = anchors[.header(folder.id)] else { return nil }
                // Resolve both boundaries in the same layout pass. Backgrounds
                // follow the animated rows, never a delayed end measurement.
                let header = geometry[anchor]
                let end = folderPreview(folder).showsPanel ? anchors[.end(folder.id)].map { geometry[$0] } : nil
                return FolderPanel(id: folder.id, frame: CGRect(x: header.minX, y: header.minY,
                    width: header.width, height: max(header.maxY, end?.maxY ?? header.maxY) - header.minY))
            }
            let affected: Set<UUID> = reduceMotion || draggingTab != nil ? [] : folderBounceEvent?.folders ?? []
            let heights = panels.filter { affected.contains($0.id) }.map(\.frame.height)
            // One clock and one pixel displacement preserve the padding between
            // nested islands. Independent percentage springs can cross edges.
            folderPanelBackgrounds(panels, affected: affected, origin: origin, size: geometry.size)
            .keyframeAnimator(initialValue: CGFloat.zero, trigger: folderBounceEvent) { layer, requested in
                let displacement = SidebarFolderBounce.displacement(requested, panelHeights: heights,
                    minimumHeight: PinnedIsland.height)
                layer.environment(\.folderBounceDisplacement, displacement)
            } keyframes: { _ in
                LinearKeyframe(CGFloat.zero, duration: 0.09)
                CubicKeyframe(SidebarFolderBounce.peakDisplacement, duration: 0.055)
                CubicKeyframe(CGFloat(-0.5), duration: 0.045)
                CubicKeyframe(CGFloat.zero, duration: 0.06)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private func folderPanelBackgrounds(_ panels: [FolderPanel], affected: Set<UUID>,
                                        origin: CGPoint, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            if showsFolderDragTargets && pinnedOutline.isEmpty, let start = dropAreas["pinned"], let end = dropAreas["pinnedEnd"] {
                groupPanel(active: destinationSection(at: dragPoint) == .pinned, dashed: true)
                    .frame(width: size.width, height: max(0, end.maxY - start.minY))
                    .offset(x: 0, y: start.minY - origin.y)
            }
            ForEach(panels) { panel in
                let highlighted = showsFolderDragTargets || hoveredFolderGroups.contains(panel.id)
                    || hoveredFolder == panel.id
                // Draw only: keep row positions and drag/hit geometry unchanged.
                // The shared envelope cannot consume the next row's spacing or
                // shrink any member of the branch below its header height.
                groupPanel(active: showsFolderDragTargets && isDropAncestor(panel.id), isFolder: true)
                    .modifier(FolderBounceDrawing(frame: panel.frame, affected: affected.contains(panel.id)))
                    // Anchor geometry already follows the row animation. A
                    // second implicit animation would make ancestors lag again.
                    .transaction { $0.animation = nil }
                    .opacity(highlighted ? 1 : 0)
                    .animation(folderDragAnimation, value: highlighted)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func previewOffset(_ id: UUID) -> CGSize {
        guard let draggingTab else { return .zero }
        if draggingTab == id { return .zero }
        guard let dragLayout else { return .zero }
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

    private func vacatesSourceRow(_ item: SidebarItem) -> Bool {
        let destination = destinationSection(at: dragPoint)
        switch item {
        case .tab(let tab, _) where draggingTab == tab.id:
            return SidebarReorderLayout.vacatesSourceRow(sourceSection: section(of: tab), sourceFolder: tab.folderID,
                destinationSection: destination, destinationFolder: dropFolder)
        case .folder(let folder, _) where draggingTab == folder.id:
            return SidebarReorderLayout.vacatesSourceRow(sourceSection: .pinned, sourceFolder: folder.parentID,
                destinationSection: destination, destinationFolder: dropFolder)
        default:
            return false
        }
    }

    private func insertionOverflow(at y: CGFloat) -> CGFloat {
        guard draggingTab != nil, let dragLayout, dragLayout.foreign, !dragLayout.grid,
              destinationSection(at: dragPoint) == .regular,
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
            model.perform(.presentCommandBar(.newTab))
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
        .buttonStyle(SidebarButtonStyle())
        .accessibilityIdentifier("sidebar.newTab")
        .help("Open the command bar (Command-T)")
    }

    private var navigationControls: some View {
        HStack(spacing: 6) {
            WindowControls().frame(width: 60, height: 32)
            Button {
                model.perform(.toggleSidebar)
                sidebarHovered = false
            } label: {
                Image(systemName: "sidebar.left").frame(width: 32, height: 32)
            }
            .accessibilityLabel(sidebarAutoHides ? "Keep sidebar visible" : "Auto-hide sidebar")
            .accessibilityValue(sidebarAutoHides ? "Auto-hide enabled" : "Always visible")
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .accessibilityIdentifier("sidebar.toggle")
            .help("Toggle sidebar auto-hide (Command-Shift-S). Reveal at the left edge.")
            Spacer(minLength: 0)
            NavigationButton(kind: .back) { model.perform(.back) }
                .disabled(model.activePage?.canGoBack != true)
                .accessibilityLabel("Back").accessibilityIdentifier("navigation.back")
            NavigationButton(kind: .forward) { model.perform(.forward) }
                .disabled(model.activePage?.canGoForward != true)
                .accessibilityLabel("Forward").accessibilityIdentifier("navigation.forward")
            NavigationButton(kind: model.activePage?.isLoading == true ? .stop : .reload) {
                if model.activePage?.isLoading == true { model.perform(.stop) }
                else { model.perform(.reload) }
            }
            .disabled(model.activePage == nil)
            .accessibilityLabel(model.activePage?.isLoading == true ? "Stop Loading" : "Reload")
            .accessibilityIdentifier(model.activePage?.isLoading == true ? "navigation.stop" : "navigation.reload")
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
            model.perform(.presentCommandBar(.navigateCurrentTab))
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

}

/// Activation feedback never delays the action or the actual Reload/Stop state.
private struct NavigationButton: View {
    let kind: NavigationControlStyle.Kind
    let action: () -> Void
    @State private var activation = 0
    @State private var clickFeedback = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            clickFeedback = !reduceMotion
            activation += 1
            action()
        } label: {
            ReloadStopArtwork(isLoading: kind == .stop)
        }
        .buttonStyle(NavigationControlStyle(kind: kind, clickFeedback: clickFeedback))
        .task(id: activation) {
            guard activation > 0 else { return }
            do {
                try await Task.sleep(for: .milliseconds(120))
                clickFeedback = false
            } catch { /* A newer activation or disappearing view cancels feedback. */ }
        }
    }
}

private struct ReloadStopArtwork: View {
    let isLoading: Bool
    @State private var motion: NavigationSymbolMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(isLoading: Bool) {
        self.isLoading = isLoading
        _motion = State(initialValue: NavigationSymbolMotion(isLoading: isLoading))
    }

    var body: some View {
        Color.clear.frame(width: 24, height: 24)
            .modifier(motion)
            .clipped()
            .onChange(of: isLoading) { _, loading in
                // Animate one persistent pair of glyphs, never insertion/removal
                // transitions. Fast loads can retarget forward through the X
                // without resetting or unwinding the rotation.
                withAnimation(reduceMotion ? nil : .linear(duration: 0.16)) {
                    motion.setLoading(loading)
                }
            }
    }
}

/// One increasing phase controls both glyphs and their shared rotation. Reload
/// is visible at even phases, X at odd phases: a complete cycle turns 360°.
struct NavigationSymbolMotion: ViewModifier, Animatable {
    // SwiftUI interpolates this value outside the view's main-actor context.
    nonisolated var phase: Double

    init(isLoading: Bool) { phase = isLoading ? 1 : 0 }
    init(phase: Double) { self.phase = phase }

    mutating func setLoading(_ loading: Bool) {
        let wasLoading = !Int(phase).isMultiple(of: 2)
        guard loading != wasLoading else { return }
        phase += 1
    }

    nonisolated var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    var rotationDegrees: Double { phase * 180 }
    var reloadOpacity: Double {
        let cycle = phase.truncatingRemainder(dividingBy: 2)
        return (1 + cos(cycle * .pi)) / 2
    }
    var stopOpacity: Double { 1 - reloadOpacity }

    func body(content: Content) -> some View {
        content
            .overlay {
                ZStack {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 18, height: 18).opacity(reloadOpacity)
                    Image(systemName: "xmark")
                        .frame(width: 18, height: 18).opacity(stopOpacity)
                }
                .rotationEffect(.degrees(rotationDegrees), anchor: .center)
                .accessibilityHidden(true)
            }
    }
}

/// Native button activation/focus semantics with a fixed hit area. Only the
/// artwork moves; hovering never shifts adjacent controls or triggers navigation.
private struct NavigationControlStyle: ButtonStyle {
    enum Kind { case back, forward, reload, stop }
    let kind: Kind
    var clickFeedback = false

    func makeBody(configuration: Configuration) -> some View {
        Appearance(configuration: configuration, kind: kind, clickFeedback: clickFeedback)
    }

    private struct Appearance: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        let clickFeedback: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private var highlighted: Bool { isEnabled && hovered }
        private var pressed: Bool { isEnabled && configuration.isPressed }

        var body: some View {
            ZStack {
                if kind == .back || kind == .forward {
                    NavigationChevron(openness: highlighted && !reduceMotion ? 1 : 0,
                                      pointsRight: kind == .forward)
                        .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                        .frame(width: 14, height: 18)
                        .offset(x: !reduceMotion && (pressed || clickFeedback)
                                ? (kind == .back ? -1 : 1) * (clickFeedback ? 3 : 1.5) : 0)
                } else {
                    configuration.label
                }
            }
            .scaleEffect((kind == .back || kind == .forward) && pressed && !reduceMotion ? 0.88 : 1)
            .frame(width: 32, height: 32)
            .background(Color.primary.opacity(pressed ? 0.13 : (highlighted ? 0.075 : 0)),
                        in: RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: highlighted)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: pressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: clickFeedback)
        }
    }
}

private struct NavigationChevron: Shape {
    var openness: CGFloat
    let pointsRight: Bool
    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        // Bring the tip toward the ends to open the chevron's interior angle.
        let tip = 0.24 + 0.05 * openness
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * (pointsRight ? 1 - x : x),
                    y: rect.minY + rect.height * y)
        }
        return Path { path in
            path.move(to: point(0.72, 0.16))
            path.addLine(to: point(tip, 0.5))
            path.addLine(to: point(0.72, 0.84))
        }
    }
}

/// Layered folder artwork shared by live rows, Space pages and drag previews.
struct FolderIcon: View {
    let isOpen: Bool
    var themeColor: BrowserSpace.Color = .gray
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var color: BrowserSpace.Color { contrast == .increased ? .gray : themeColor }

    private var outline: Color {
        colorScheme == .dark
            ? Color(white: 0.83)
            : Color(white: 0.38)
    }

    var body: some View {
        ZStack {
            FolderBack()
                .fill(color.folderBack(isDark: colorScheme == .dark).color)
                .overlay {
                    FolderBack().stroke(outline, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                }
            FolderCover(openness: isOpen ? 1 : 0)
                .fill(color.folderFront(isDark: colorScheme == .dark).color)
                .overlay {
                    FolderCover(openness: isOpen ? 1 : 0)
                        .stroke(outline, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                }
        }
    }
}

private struct FolderBack: Shape {

    func path(in rect: CGRect) -> Path {
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        let right: CGFloat = 0.88
        path.move(to: point(0.18, 0.88))
        path.addQuadCurve(to: point(0.06, 0.76), control: point(0.06, 0.88))
        path.addLine(to: point(0.06, 0.23))
        path.addQuadCurve(to: point(0.18, 0.11), control: point(0.06, 0.11))
        path.addLine(to: point(0.34, 0.11))
        path.addQuadCurve(to: point(0.41, 0.15), control: point(0.38, 0.11))
        path.addLine(to: point(0.47, 0.23))
        path.addQuadCurve(to: point(0.54, 0.27), control: point(0.50, 0.27))
        path.addLine(to: point(right - 0.12, 0.27))
        path.addQuadCurve(to: point(right, 0.39), control: point(right, 0.27))
        path.addLine(to: point(right, 0.76))
        path.addQuadCurve(to: point(right - 0.12, 0.88), control: point(right, 0.88))
        path.closeSubpath()
        return path
    }
}

private struct FolderCover: Shape {
    var openness: CGFloat
    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        func blended(_ x: CGFloat, _ y: CGFloat, _ openX: CGFloat, _ openY: CGFloat) -> CGPoint {
            point(x + (openX - x) * openness, y + (openY - y) * openness)
        }
        var path = Path()
        // Matching control points let the cover smoothly unfold, without
        // crossfading two overlapping outlines halfway through the animation.
        path.move(to: point(0.18, 0.88))
        path.addQuadCurve(to: blended(0.06, 0.76, 0.12, 0.80), control: blended(0.06, 0.88, 0.10, 0.88))
        path.addLine(to: blended(0.06, 0.46, 0.27, 0.43))
        path.addQuadCurve(to: blended(0.18, 0.34, 0.37, 0.37), control: blended(0.06, 0.34, 0.30, 0.37))
        path.addLine(to: blended(0.82, 0.34, 0.89, 0.37))
        path.addQuadCurve(to: blended(0.94, 0.46, 0.96, 0.46), control: blended(0.94, 0.34, 1.00, 0.37))
        path.addLine(to: blended(0.94, 0.76, 0.84, 0.81))
        path.addQuadCurve(to: blended(0.82, 0.88, 0.74, 0.88), control: blended(0.94, 0.88, 0.81, 0.88))
        path.closeSubpath()
        return path
    }
}
