// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import EarlyWeb
import SwiftUI

/// Folder rows and the frames the sidebar's reordering measures.
extension BrowserWindowView {
    func folderRow(_ folder: BrowserFolder) -> some View {
        let header = HStack(spacing: 4) {
            // Neither disclosure nor title waits for a possible second click.
            Button { toggleFolder(folder) } label: {
                FolderIcon(isOpen: isFolderOpen(folder), themeColor: folderTheme(folder), emblem: FolderEmblem(folder))
                    .frame(width: FolderIcon.width, height: FolderIcon.height)
                    .animation(folderExpansionAnimation, value: isFolderOpen(folder))
                    .frame(width: PinnedIsland.iconControlWidth, height: PinnedIsland.height)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }
            .buttonStyle(SidebarButtonStyle())
            .focused($focusedSidebarControl, equals: .folderToggle(folder.id))
            .focusEffectDisabled()
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
            .focusEffectDisabled()
            .accessibilityIdentifier("folder.\(folder.id)")
            .accessibilityLabel(folder.name)
            .accessibilityValue(isFolderOpen(folder) ? "Expanded" : "Collapsed")
            .accessibilityHint("Click to expand or collapse. Option-click to rename.")
            .accessibilityActions {
                Button("Rename Folder") { editFolder(folder, parent: folder.parentID) }
                if model.coordinator.tabStore.canCreateFolder(in: folder.id, spaceID: folder.spaceID) {
                    Button("New Subfolder") { editFolder(nil, parent: folder.id) }
                }
            }
            .highPriorityGesture(folderClickGesture(folder))
        }
        .padding(.leading, PinnedIsland.leadingInset)
        .padding(.trailing, 8)
        return header
        .help(folderPath(folder))
        // The anchored group panel owns the hover fill, including when closed.
        // A second header island leaves darker, mismatched corners over it.
        .overlay {
            BrowserFocusOutline(focused: focusedSidebarControl == .folder(folder.id)
                || focusedSidebarControl == .folderToggle(folder.id), cornerRadius: PinnedIsland.cornerRadius)
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
        .opacity(hiddenDragItemID == folder.id ? 0 : 1)
        .animation(nil, value: hiddenDragItemID == folder.id)
        .animation(dragSourceItem == nil || reduceMotion ? nil : .easeInOut(duration: 0.16), value: previewOffset(folder.id))
        .background(tabFrame(folder.id))
        .contextMenu {
            if let live = folder.live, let feed = model.pullRequests {
                Text(Self.lastFetch(feed))
                // A picker, so the menu checks the current choice.
                Picker("Fetch Interval", selection: Binding(get: { live.interval }, set: { interval in
                    if model.coordinator.setLiveFolderInterval(folder.id, interval) { model.save() }
                })) {
                    ForEach(LiveFolder.Interval.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                Button("Refresh") { feed.refresh() }
                    .disabled(feed.isRefreshing)
                Button("Open Pull Requests on GitHub") { _ = model.openLocations([PullRequest.github.appending(path: "pulls")]) }
                Divider()
            } else {
                Button("New Subfolder…") { editFolder(nil, parent: folder.id) }
                    .disabled(!model.coordinator.tabStore.canCreateFolder(in: folder.id, spaceID: folder.spaceID))
            }
            Button("Rename Folder…") { editFolder(folder, parent: folder.parentID) }
            // A live folder shows its source's mark.
            if folder.live == nil {
                Button("Change Icon…") { iconFolderID = folder.id }
            }
            Menu("Move to Space") {
                ForEach(model.coordinator.spaces) { space in
                    Button(space.name) {
                        endDrag()
                        hoveredFolder = nil
                        focusedSidebarControl = nil
                        model.perform(.moveFolder(folder.id, toSpace: space.id))
                    }
                    .disabled(space.id == folder.spaceID
                              || folder.live.map { model.coordinator.tabStore.hasLiveFolder($0.source, in: space.id) } == true)
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

    /// "Last fetch: 49 seconds ago", as of when the menu opens.
    static func lastFetch(_ feed: PullRequestFeed, now: Date = Date()) -> String {
        if feed.isRefreshing { return "Fetching…" }
        guard let date = feed.lastRefreshed else { return "Not fetched yet" }
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return "Last fetch: \(max(Int(elapsed), 1)) seconds ago" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last fetch: " + formatter.localizedString(for: date, relativeTo: now)
    }

    func folderTheme(_ folder: BrowserFolder) -> BrowserSpace.Color {
        guard model.preferences.spaceThemes else { return .gray }
        // Neighboring Space pages and drag previews retain their own theme.
        return model.coordinator.spaces.first { $0.id == folder.spaceID }?.color ?? .gray
    }

    enum SidebarFrame: Hashable {
        case item(UUID), folderHeader(UUID), section(Bool), dropArea(String), landingLayout(UUID)
    }

    struct SidebarFrames: PreferenceKey {
        static let defaultValue: [SidebarFrame: CGRect] = [:]
        static func reduce(value: inout [SidebarFrame: CGRect], nextValue: () -> [SidebarFrame: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { _, new in new })
        }
    }

    func folderHitFrame(_ id: UUID) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: SidebarFrames.self,
                value: [.folderHeader(id): geometry.frame(in: .named("sidebarReordering"))])
        }.allowsHitTesting(false)
    }

    func tabFrame(_ id: UUID) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: SidebarFrames.self,
                                   value: [.item(id): geometry.frame(in: .named("sidebarReordering"))])
        }
        .allowsHitTesting(false)
    }

    func sectionFrame(favorites: Bool) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: SidebarFrames.self,
                                   value: [.section(favorites): geometry.frame(in: .named("sidebarReordering"))])
        }
        .allowsHitTesting(false)
    }
}
