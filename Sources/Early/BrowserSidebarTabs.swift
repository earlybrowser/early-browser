// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import EarlyWeb
import SwiftUI

/// The sidebar's tab rows, their media and close controls, and Favorites.
extension BrowserWindowView {
    func tabRowContent(_ tab: BrowserTab, selected: Bool, requestsArtwork: Bool) -> some View {
        let hasMedia = showsMediaControl(tab)
        let hasLeadingMedia = tab.pinnedURL == nil && hasMedia
        return HStack(spacing: tab.hasNavigatedFromPin ? 1 : 4) {
            if tab.pinnedURL != nil {
                HStack(spacing: hasMedia ? (tab.hasNavigatedFromPin ? 1 : 4) : 0) {
                    PinnedTabIcon(tab: tab, favicons: model.webViews.favicons, page: model.webViews.pages[tab.id],
                                  reset: { model.perform(.resetPinnedTab(tab.id)) }, requestsArtwork: requestsArtwork)
                    tabMediaSlot(tab, visible: hasMedia)
                }
            }
            Button { model.perform(.selectTab(tab.id)) } label: {
                HStack(spacing: tab.hasNavigatedFromPin ? 3 : (hasLeadingMedia ? 4 : 8)) {
                    if tab.pinnedURL == nil {
                        HStack(spacing: hasLeadingMedia ? 8 : 0) {
                            TabArtwork(tab: tab, store: model.webViews.favicons, page: model.webViews.pages[tab.id],
                                       size: 16, requestsArtwork: requestsArtwork)
                            Color.clear.frame(width: hasLeadingMedia ? 24 : 0, height: 16)
                                .accessibilityHidden(true)
                        }
                    }
                    if tab.hasNavigatedFromPin {
                        Text("/").foregroundStyle(.tertiary).accessibilityHidden(true)
                    }
                    sidebarTabTitle(tab)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(tab.isOpen ? .primary : .secondary)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(SidebarButtonStyle())
            .focused($focusedSidebarControl, equals: .tab(tab.id))
            .focusEffectDisabled()
            .accessibilityIdentifier("tab.\(tab.id)")
            .accessibilityLabel(tab.displayTitle)
            .accessibilityValue(tabAccessibilityValue(tab))
            .accessibilityHint(tab.isOpen ? "Select tab. Option-click to rename. More actions in the context menu." : "Reopen saved tab. Option-click to rename.")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .modifier(BrowserTabAccessibilityActions(model: model, tab: tab))
            .help(tab.pinnedURL.map { "Pinned URL: \($0.absoluteString)\nCurrent URL: \(tab.currentURL.absoluteString)\(tab.isOpen ? "" : "\nClick to reopen")" }
                  ?? tab.currentURL.absoluteString)
            .highPriorityGesture(tabClickGesture(tab))
            .overlay(alignment: .leading) {
                if tab.pinnedURL == nil {
                    // Beside the favicon, but outside the select/rename/drag
                    // control. Reserving width above preserves the row height.
                    tabMediaSlot(tab, visible: hasLeadingMedia).offset(x: 24)
                }
            }
            if tab.isOpen && hoveredTab == tab.id {
                Button { model.perform(.closeTab(tab.id)) } label: {
                    tabControlLabel("xmark", highlighted: true)
                }
                    .buttonStyle(SidebarButtonStyle())
                    .focused($focusedSidebarControl, equals: .close(tab.id))
                    .focusEffectDisabled()
                    .accessibilityIdentifier("tabClose.\(tab.id)")
                    .accessibilityLabel("Close \(tab.displayTitle)")
                    .help(tab.pinnedURL == nil ? "Close tab" : "Close page and keep pin")
            }
        }
        // The 24-point reset control adds four points around its 16-point
        // artwork. Together with this inset, both sections put the artwork
        // at x=8 and the title at x=32 (or x=60 with a media control).
        .padding(.leading, tab.pinnedURL == nil ? 8 : PinnedIsland.leadingInset)
        .padding(.trailing, 8)
    }

    func tabRow(_ tab: BrowserTab, selected: Bool, requestsArtwork: Bool) -> some View {
        let focused = focusedSidebarControl == .tab(tab.id) || focusedSidebarControl == .close(tab.id)
            || focusedSidebarControl == .media(tab.id)
        let cornerRadius: CGFloat = tab.pinnedURL == nil ? 7 : PinnedIsland.cornerRadius
        let hasMedia = showsMediaControl(tab)
        return tabRowContent(tab, selected: selected, requestsArtwork: requestsArtwork)
        .animation(reduceMotion || draggingTab != nil ? nil : .easeInOut(duration: 0.18), value: hasMedia)
        .background(Color.primary.opacity(selected ? (contrast == .increased ? 0.18 : 0.08) : (hoveredTab == tab.id ? 0.04 : 0)))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay {
            BrowserFocusOutline(focused: focused, cornerRadius: cornerRadius)
            if selected, contrast == .increased {
                RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.primary, lineWidth: 1)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .onHover { updateTabHover(tab.id, hovering: $0) }
        .background(draggingTab == tab.id ? Color(nsColor: .windowBackgroundColor) : .clear,
                    in: RoundedRectangle(cornerRadius: cornerRadius))
        .shadow(color: .black.opacity(draggingTab == tab.id ? 0.18 : 0), radius: 6, y: 3)
        .offset(previewOffset(tab.id))
        .opacity(hiddenDragItemID == tab.id ? 0 : 1)
        .animation(nil, value: hiddenDragItemID == tab.id)
        .zIndex(draggingTab == tab.id ? 1 : 0)
        .animation(dragSourceItem == nil || draggingTab == tab.id || reduceMotion ? nil : .easeInOut(duration: 0.16), value: previewOffset(tab.id))
        .background(tabFrame(tab.id))
        .contextMenu { tabActions(tab) }
    }

    func updateTabHover(_ id: UUID, hovering: Bool) {
        if hovering { hoveredTab = id }
        else if hoveredTab == id { hoveredTab = nil }
    }

    // Use the same typography in the live row, drag proxy, and landing proxy.
    // A callout font in the proxy makes the title shrink on pickup and grow
    // again when the real row becomes visible.
    func sidebarTabTitle(_ tab: BrowserTab) -> some View {
        Text(tab.displayTitle)
            .font(.body)
            .foregroundStyle(tab.isOpen ? .primary : .secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    func showsMediaControl(_ tab: BrowserTab) -> Bool {
        guard !tab.isFavorite, tab.isOpen, let page = model.webViews.pages[tab.id] else { return false }
        return page.isPlayingMedia || page.isMuted
    }

    func tabControlLabel(_ symbol: String, highlighted: Bool) -> some View {
        Image(systemName: symbol).font(.caption)
            .frame(width: 24, height: 24)
            .background(Color.primary.opacity(highlighted ? 0.12 : 0),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .contentTransition(.opacity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: symbol)
    }

    func tabMediaSlot(_ tab: BrowserTab, visible: Bool) -> some View {
        // Animate the reserved width and glyph together, clipping the control
        // to its growing/shrinking slot so it never overlaps the sliding title.
        tabMediaButton(tab)
            .frame(width: visible ? 24 : 0, alignment: .leading)
            .opacity(visible ? 1 : 0)
            .clipped()
            .contentShape(Rectangle())
            .allowsHitTesting(visible)
            .disabled(!visible)
            .accessibilityHidden(!visible)
            .onChange(of: visible) { _, visible in
                if !visible && hoveredMedia == tab.id { hoveredMedia = nil }
            }
    }

    func tabMediaButton(_ tab: BrowserTab) -> some View {
        let muted = model.webViews.pages[tab.id]?.isMuted == true
        let hovered = hoveredMedia == tab.id
        return Button { model.perform(.setMuted(tab.id, !muted)) } label: {
            tabControlLabel(muted ? "speaker.slash.fill" : "speaker.wave.3.fill", highlighted: hovered)
        }
        .buttonStyle(SidebarButtonStyle())
        .focused($focusedSidebarControl, equals: .media(tab.id))
        .focusEffectDisabled()
        .onHover { inside in
            if inside { hoveredMedia = tab.id }
            else if hoveredMedia == tab.id { hoveredMedia = nil }
        }
        .onDisappear { if hoveredMedia == tab.id { hoveredMedia = nil } }
        .accessibilityIdentifier("tabMute.\(tab.id)")
        .accessibilityLabel("\(muted ? "Unmute" : "Mute") \(tab.displayTitle)")
        .accessibilityValue(muted ? "Muted" : "Media playing")
        .accessibilityHint("Changes this tab’s sound without selecting it.")
        .help(muted ? "Unmute tab" : "Mute tab")
        .disabled(!model.canPerform(.setMuted(tab.id, !muted)))
    }

    func tabAccessibilityValue(_ tab: BrowserTab) -> String {
        let page = model.webViews.pages[tab.id]
        return BrowserTabAccessibility.value(for: tab, isLoading: page?.isLoading == true,
            hasFailure: page?.failure != nil, isMuted: page?.isMuted == true, isPlayingMedia: page?.isPlayingMedia == true)
    }

    @ViewBuilder
    func tabActions(_ tab: BrowserTab) -> some View {
        Button("Duplicate Tab") { model.perform(.duplicateTab(tab.id)) }
        Button("Open Tab in New Window") { model.perform(.openTabInNewWindow(tab.id)) }
        Button("Rename Tab…") { model.perform(.requestRename(tab.id)) }
        Menu("Split View") {
            if let group = model.splitGroup(containing: tab.id) {
                Button("Swap Sides") { model.perform(.swapSplit(group.id)) }
                    .disabled(!model.canPerform(.swapSplit(group.id)))
                Button("Exit Split View") { model.perform(.exitSplit(group.id)) }
                    .disabled(!model.canPerform(.exitSplit(group.id)))
            } else {
                Button("Place on Left") { model.perform(.splitTab(tab.id, .leading)) }
                    .disabled(!model.canPerform(.splitTab(tab.id, .leading)))
                Button("Place on Right") { model.perform(.splitTab(tab.id, .trailing)) }
                    .disabled(!model.canPerform(.splitTab(tab.id, .trailing)))
            }
        }
        if let page = model.webViews.pages[tab.id] {
            Button(page.isMuted ? "Unmute Tab" : "Mute Tab") {
                model.perform(.setMuted(tab.id, !page.isMuted))
            }
            .disabled(!model.canPerform(.setMuted(tab.id, !page.isMuted)))
        }
        if !tab.isFavorite && !model.isPrivate && tab.liveItemID == nil {
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
                        .disabled(tab.folderID == folder.id || folder.live != nil)
                }
            }
        }
        // A live folder's pins keep GitHub's order and stay in their folder.
        if tab.liveItemID == nil {
            Button("Move Up") { model.perform(.moveTabBy(tab.id, -1)) }
                .disabled(model.coordinator.tabStore.siblingIDs(of: tab).first == tab.id)
            Button("Move Down") { model.perform(.moveTabBy(tab.id, 1)) }
                .disabled(model.coordinator.tabStore.siblingIDs(of: tab).last == tab.id)
        }
        if !model.isPrivate && tab.liveItemID == nil {
            Button(tab.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                model.perform(.setFavorite(tab.id, !tab.isFavorite))
            }
            if !tab.isFavorite {
                Button(tab.pinnedURL == nil ? "Pin Tab" : "Unpin Tab") {
                    model.perform(.setPinned(tab.id, tab.pinnedURL == nil))
                }
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
        if tab.liveItemID != nil {
            Button("Remove from Folder") { model.removeLiveItem(tab.id) }
                .help("Remove this pull request from the folder. It won’t come back while it’s open on GitHub.")
        }
        if tab.pinnedURL == nil && !tab.isFavorite {
            Button("Close Other Tabs") { model.perform(.closeOtherTabs(tab.id)) }
                .disabled(!model.canPerform(.closeOtherTabs(tab.id)))
            Button("Close Tabs Below") { model.perform(.closeTabsBelow(tab.id)) }
                .disabled(!model.canPerform(.closeTabsBelow(tab.id)))
        }
    }

    func emptySavedSectionTarget(_ title: String, preview: SidebarSavedSectionPreview,
                                         identifier: String) -> some View {
        // Keep the old empty target drawn until its closing layout starts;
        // clearing gesture state must not make the border blink off first.
        let showsOutline = preview.showsOutline || (dragLanding != nil && revealDropSections)
        return Text(title).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: preview.height, maxHeight: preview.height, alignment: .center)
            .background {
                if showsOutline { groupPanel(active: preview.isActive, dashed: true) }
            }
            .transition(.opacity)
            .accessibilityIdentifier(identifier)
            .allowsHitTesting(false)
    }

    var favoritesContentHeight: CGFloat {
        let count = model.favorites.count + (receivingFavorite ? 1 : 0)
        return max(SidebarReorderLayout.favoriteHeight,
                   CGFloat((count + 3) / 4) * SidebarReorderLayout.favoriteRowStride - 6)
    }

    var favoritesViewportHeight: CGFloat {
        min(favoritesContentHeight, SidebarReorderLayout.favoriteRowStride * 3 - 6)
    }

    var favoritesSection: some View {
        let preview = SidebarSavedSectionPreview(section: .favorites, itemIDs: model.favorites.map(\.id),
            draggingItemID: dragSourceItem != nil ? draggingTab : nil,
            isTargeted: destinationSection(at: dragPoint) == .favorites)
        return ScrollView {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    ForEach(visibleFavorites) { tab in
                        let frame = favoriteDisplayFrame(tab.id, width: geometry.size.width)
                        favoriteTile(tab)
                            .frame(width: frame.width, height: frame.height)
                            .background(tabFrame(tab.id))
                            .position(x: frame.midX, y: frame.midY)
                            .animation(dragSourceItem == nil || draggingTab == tab.id || reduceMotion ? nil : .easeInOut(duration: 0.16), value: frame)
                    }
                    if preview.showsEmptyTarget {
                        emptySavedSectionTarget("Favorites", preview: preview,
                            identifier: "sidebar.favorites.dropTarget")
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(height: favoritesContentHeight)
            .background(dropArea("favoriteContent"))
        }
        .frame(height: favoritesViewportHeight)
        .accessibilityIdentifier("sidebar.favorites")
        .background(sectionFrame(favorites: true))
        .background(dropArea("favorites"))
    }

    func favoriteDisplayFrame(_ id: UUID, width: CGFloat) -> CGRect {
        let original = model.favorites.map(\.id)
        var order = original
        if let draggingTab, dragSourceItem != nil {
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

    var visibleFavorites: [BrowserTab] {
        guard let content = dropAreas["favoriteContent"], let viewport = sectionFrames[true] else {
            return Array(model.favorites.prefix(12))
        }
        // Keep scrolling collections bounded, and retain the drag source even
        // when its preview leaves the viewport so its gesture can finish.
        let frames = SidebarReorderLayout.favoriteFrames(count: model.favorites.count, in: content)
        let visible = viewport.insetBy(dx: 0, dy: -SidebarReorderLayout.favoriteRowStride)
        return zip(model.favorites, frames).compactMap { tab, frame in
            tab.id == hiddenDragItemID || frame.intersects(visible) ? tab : nil
        }
    }

    func favoriteTile(_ tab: BrowserTab) -> some View {
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
        .focusEffectDisabled()
        .overlay {
            BrowserFocusOutline(focused: focusedSidebarControl == .favorite(tab.id), cornerRadius: 9)
            if selected, contrast == .increased {
                RoundedRectangle(cornerRadius: 9).strokeBorder(.primary, lineWidth: 1)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .onHover { updateTabHover(tab.id, hovering: $0) }
        .accessibilityIdentifier("favorite.\(tab.id)")
        .accessibilityLabel(name)
        .accessibilityValue(tabAccessibilityValue(tab))
        .accessibilityHint(tab.isOpen ? "Select favorite. Option-click to rename. More actions in the context menu." : "Reopen saved favorite. Option-click to rename.")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .modifier(BrowserTabAccessibilityActions(model: model, tab: tab))
        .help("\(name)\n\((tab.pinnedURL ?? tab.currentURL).absoluteString)")
        .highPriorityGesture(tabClickGesture(tab))
        .opacity(hiddenDragItemID == tab.id ? 0 : 1)
        .animation(nil, value: hiddenDragItemID == tab.id)
        .zIndex(draggingTab == tab.id ? 1 : 0)
        .contextMenu { tabActions(tab) }
    }

    func favoriteTint(_ tab: BrowserTab) -> Color? {
        guard let color = model.webViews.favicons.color(for: tab.pinnedURL ?? tab.currentURL) else { return nil }
        let iconColor = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        iconColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: hue, saturation: min(saturation * 0.55, 0.50),
                     brightness: colorScheme == .dark ? 0.72 : 0.64)
    }

    /// The title selects/reopens a pin. Its icon is interactive only for reset
    /// when a live page has navigated away from the saved address.
    struct PinnedTabIcon: View {
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
                    .frame(width: PinnedIsland.iconControlWidth, height: PinnedIsland.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SidebarButtonStyle())
            .disabled(!canReset)
            .focused($focused)
            .focusEffectDisabled()
            .overlay {
                BrowserFocusOutline(focused: focused)
            }
            .onHover { hovered = $0 }
            .accessibilityIdentifier("\(canReset ? "pinReset" : "pinSelect").\(tab.id)")
            .accessibilityLabel(canReset ? "Reset \(tab.customTitle ?? tab.pinnedTitle ?? tab.title) to pinned URL" : "Saved page icon")
            .help(canReset ? "Reset pinned tab" : "Saved page")
        }
    }

    /// Disabled neighbor pages and unavailable pin-reset actions stay visually
    /// unchanged. PlainButtonStyle would dim them, then flash on selection.
    struct SidebarButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
        }
    }

    /// Artwork is independent of loading state; unloaded pins never allocate
    /// a web view or start navigation just to display an icon.
    struct TabArtwork: View {
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

    struct SiteIcon: View {
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

    func editFolder(_ folder: BrowserFolder?, parent: UUID?) {
        editingFolder = folder?.id
        folderParent = parent
        folderName = folder?.name ?? ""
        folderIcon = folder?.icon
        folderEditor = true
    }

    func folderPath(_ folder: BrowserFolder) -> String {
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
}
