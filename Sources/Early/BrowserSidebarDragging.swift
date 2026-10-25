// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import EarlyWeb
import SwiftUI

/// Reordering in the sidebar: dragging tabs and folders, their previews,
/// drop areas and the folder panels behind pinned groups.
extension BrowserWindowView {
    func itemFrame(_ id: UUID) -> CGRect? {
        if let index = model.favorites.firstIndex(where: { $0.id == id }),
           let bounds = dropAreas["favoriteContent"] {
            return SidebarReorderLayout.favoriteFrames(
                count: model.favorites.count + (receivingFavorite ? 1 : 0), in: bounds)[index]
        }
        return frozenFrames[id] ?? tabFrames[id]
    }

    func beginDrag(_ item: SidebarDragItem) {
        guard let frame = itemFrame(item.id) else { return }
        endDrag()
        model.sidebarInteractionInProgress = true
        BrowserHaptics.pickupOrDrop(enabled: model.preferences.haptics)
        dragSourceItem = item
        frozenFrames = tabFrames
        dragSourceFrame = frame
        switch item {
        case .tab(let tab): dropFolder = section(of: tab) == .pinned ? tab.folderID : nil
        case .folder(let folder): dropFolder = folder.parentID
        }
        updateFolderDropSlot(dropFolder)
        refreshCurrentDrag()
    }

    func revealSavedSections() {
        guard !revealDropSections else { return }
        // Private windows have no Pins or Favorites to drop into.
        withAnimation(folderDragAnimation) { revealDropSections = !model.isPrivate }
    }

    func endDrag() {
        model.cancelSplitPreview()
        var instant = Transaction(animation: nil)
        instant.disablesAnimations = true
        withTransaction(instant) {
            clearDragPreview()
            dragLanding = nil
            landingLayoutReady = false
            revealDropSections = false
            model.sidebarInteractionInProgress = false
        }
    }

    func clearDragPreview() {
        dragSourceItem = nil
        dragFeedbackTarget = nil
        pendingFolder = nil
        dropFolder = nil
        previousDragPoint = nil
        insertionContainer = nil
        insertionSiblings = []
        insertionIndex = nil
        reservedFolderSlot = nil
        dragLayout = nil
        dragTranslation = .zero
        contentDragTranslationX = 0
        dragSourceFrame = .zero
        frozenFrames = [:]
    }

    func finishDrag(item: SidebarDragItem, destination: TabStore.Section? = nil,
                            folderID: UUID? = nil, placement: (() -> Bool)? = nil) {
        let releasedSection = previewSection(for: item)
        let releasedFrame = dragPreviewFrame(for: item, section: releasedSection)
        let motion = SidebarDragSettlement(itemID: item.id, releasedFrame: releasedFrame)
        let sourceSection: TabStore.Section
        let sourceFolder: UUID?
        switch item {
        case .tab(let tab): sourceSection = section(of: tab); sourceFolder = tab.folderID
        case .folder(let folder): sourceSection = .pinned; sourceFolder = folder.parentID
        }
        var placed = false
        var instant = Transaction(animation: nil)
        instant.disablesAnimations = true
        withTransaction(instant) {
            placed = placement?() ?? false
            if let motion {
                dragLanding = DragLanding(motion: motion, item: item, releasedSection: releasedSection,
                    section: placed ? (destination ?? sourceSection) : sourceSection,
                    folderID: placed ? folderID : sourceFolder)
            }
            landingLayoutReady = false
            // Atomically replace the preview with the saved order. Letting
            // old offsets animate back over new rows produces the release jump.
            clearDragPreview()
            if motion == nil { revealDropSections = false }
            model.sidebarInteractionInProgress = motion != nil
        }
        if placed { BrowserHaptics.pickupOrDrop(enabled: model.preferences.haptics) }
    }

    func settleDragLanding(frames: [UUID: CGRect], sections: [Bool: CGRect], areas: [String: CGRect]) {
        guard var landing = dragLanding, landingLayoutReady else { return }
        let viewport = sections[landing.section == .favorites]
        let row = frames[landing.motion.itemID]
        let visible = row.map { frame in viewport.map { $0.intersects(frame) } ?? false } ?? false
        var destination = row
        if destination == nil {
            // A closed/offscreen folder may have no child row. Land at the
            // nearest visible ancestor and fade out, without opening/loading it.
            var parent = landing.folderID, seen = Set<UUID>()
            while let id = parent, seen.insert(id).inserted {
                if let frame = frames[id] { destination = frame; break }
                parent = model.coordinator.folders.first { $0.id == id }?.parentID
            }
        }
        let fallback = areas[landing.section == .favorites ? "favorites" : (landing.section == .pinned ? "pinned" : "regular")]
        let frame = destination ?? fallback.map {
            CGRect(x: $0.minX, y: $0.minY, width: max(1, $0.width), height: landing.motion.frame.height)
        } ?? landing.motion.frame
        guard let animationID = landing.motion.retarget(to: frame, visible: visible, layoutID: landing.id) else { return }
        let id = landing.id
        withAnimation(folderDragAnimation, completionCriteria: .logicallyComplete) {
            dragLanding = landing
        } completion: {
            guard var current = dragLanding, current.id == id,
                  current.motion.complete(animationID: animationID) else { return }
            withAnimation(folderDragAnimation) {
                dragLanding = nil
                landingLayoutReady = false
                model.sidebarInteractionInProgress = false
            }
        }
    }

    func refreshCurrentDrag() {
        guard let id = draggingTab, dragSourceItem != nil, dragLanding == nil else { return }
        if let tab = model.coordinator.tabStore.tab(id: id) {
            refreshDragLayout(for: tab, at: dragPoint)
        } else if let folder = model.coordinator.folders.first(where: { $0.id == id }) {
            refreshFolderDragLayout(folder, at: dragPoint)
        }
    }

    func refreshFolderDragLayout(_ folder: BrowserFolder, at point: CGPoint) {
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

    func refreshDragLayout(for tab: BrowserTab, at point: CGPoint) {
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

    func installDragLayout(source: UUID, slots: [SidebarReorderLayout.Slot], bounds: CGRect,
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

    func destinationSlots(in destination: TabStore.Section, folderID: UUID?) -> [SidebarReorderLayout.Slot] {
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

    func folderChildHeaderFrame(_ id: UUID) -> CGRect? {
        itemFrame(id).map { header in
            CGRect(x: header.minX + 12, y: header.minY,
                   width: max(1, header.width - 16), height: header.height)
        }
    }

    func destinationBounds(in destination: TabStore.Section, folderID: UUID?, slots: [SidebarReorderLayout.Slot]) -> CGRect {
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

    var pinnedOutline: [(id: UUID, depth: Int, isFolder: Bool)] {
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

    func containerFolder(at point: CGPoint) -> UUID? {
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

    func depth(of folder: BrowserFolder) -> Int {
        var depth = 0, parent = folder.parentID, seen: Set<UUID> = [folder.id]
        while let id = parent, seen.insert(id).inserted,
              let ancestor = model.coordinator.folders.first(where: { $0.id == id }) {
            depth += 1
            parent = ancestor.parentID
        }
        return depth
    }

    func nestTarget(at point: CGPoint) -> UUID? {
        guard sectionFrames[false]?.contains(point) == true else { return nil }
        let visible = Set(pinnedOutline.filter(\.isFolder).map(\.id))
        let headers = model.coordinator.folders.compactMap { folder -> (id: UUID, frame: CGRect)? in
            // These are the same unoffset frames used by sibling insertion,
            // not folderHitFrames, which follow the animated preview. Otherwise
            // inserting before a child moves its hit target away and can keep
            // the drop trapped in its parent forever, even during a long hold.
            guard visible.contains(folder.id), validFolderTarget(folder.id),
                  let frame = itemFrame(folder.id) else { return nil }
            return (folder.id, frame)
        }
        return SidebarFolderPreview.nestingTarget(at: point, headers: headers,
            retaining: [pendingFolder, dropFolder].compactMap { $0 })
    }

    func validFolderTarget(_ id: UUID) -> Bool {
        guard let source = draggingTab, model.coordinator.folders.contains(where: { $0.id == source }) else { return true }
        return model.coordinator.tabStore.canMoveFolder(source, to: id)
    }

    func nextFolderOnDownwardExit(at point: CGPoint, previous: CGPoint) -> UUID? {
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

    func updateFolderHover(at point: CGPoint) {
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

    func settleFolderHover(_ target: UUID?) {
        pendingFolder = target
        dropFolder = target
        updateFolderDropSlot(target)
    }

    func retainsFolderNearBoundary(at point: CGPoint, enclosing: UUID?) -> Bool {
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

    func updateFolderDropSlot(_ target: UUID?) {
        // Reordering within this folder already has the source row as its slot.
        // A second trailing slot adds a spurious blank row beneath the children.
        let slot = target.flatMap { needsPinInsertionSpace(in: $0) ? $0 : nil }
        guard reservedFolderSlot != slot else { return }
        withAnimation(folderDragAnimation) {
            reservedFolderSlot = slot
        }
    }

    func folderReorderGesture(_ folder: BrowserFolder) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("sidebarReordering"))
            .updating($dragGestureItemID) { _, state, _ in state = folder.id }
            .onChanged { value in
                guard cancelledGestureItemID != folder.id,
                      model.coordinator.commandBar == nil, model.renamingTabID == nil else { return }
                dragPoint = value.location
                if dragSourceFrame == .zero { beginDrag(.folder(folder)) }
                guard dragSourceItem?.id == folder.id else { return }
                revealSavedSections()
                dragTranslation = CGSize(width: 0, height: value.translation.height)
                updateFolderHover(at: value.location)
                refreshFolderDragLayout(folder, at: value.location)
            }
            .onEnded { value in
                guard model.coordinator.commandBar == nil, model.renamingTabID == nil,
                      dragSourceItem?.id == folder.id else { endDrag(); return }
                dragPoint = value.location
                dragTranslation = CGSize(width: 0, height: value.translation.height)
                updateFolderHover(at: value.location)
                guard destinationSection(at: value.location) == .pinned else { finishDrag(item: .folder(folder)); return }
                refreshFolderDragLayout(folder, at: value.location)
                let parent = dropFolder
                let insertion = dragLayout?.insertion(at: value.location)
                guard dragLayout != nil, insertion != nil || parent != folder.parentID else {
                    finishDrag(item: .folder(folder)); return
                }
                finishDrag(item: .folder(folder), destination: .pinned, folderID: parent) {
                    guard model.coordinator.placeFolder(folder.id, in: parent, before: insertion?.before) else { return false }
                    model.save(); return true
                }
            }
    }

    func toggleFolder(_ folder: BrowserFolder) {
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
        // Opening a live folder reads it again if it's been a while.
        if folder.live != nil, !folder.isExpanded { model.pullRequests?.refreshIfStale() }
        model.save()
    }

    func tabClickGesture(_ tab: BrowserTab) -> some Gesture {
        // Only Option-click competes with the button's immediate action. There
        // is no double-click timer; a drag takes priority over renaming.
        reorderGesture(tab).exclusively(before:
            TapGesture().modifiers(.option).onEnded { model.perform(.requestRename(tab.id)) }
        )
    }

    func folderClickGesture(_ folder: BrowserFolder) -> some Gesture {
        folderReorderGesture(folder).exclusively(before:
            TapGesture().modifiers(.option).onEnded { editFolder(folder, parent: folder.parentID) }
        )
    }

    func reorderGesture(_ tab: BrowserTab) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("sidebarReordering"))
            .updating($dragGestureItemID) { _, state, _ in state = tab.id }
            .onChanged { value in
                // A live folder's pins stay where their source puts them.
                guard cancelledGestureItemID != tab.id, tab.liveItemID == nil,
                      model.coordinator.commandBar == nil, model.renamingTabID == nil else { return }
                dragPoint = value.location
                if dragSourceFrame == .zero { beginDrag(.tab(tab)) }
                guard dragSourceItem?.id == tab.id else { return }
                revealSavedSections()
                contentDragTranslationX = value.translation.width
                dragTranslation = CGSize(width: tab.isFavorite ? value.translation.width : 0,
                                         height: value.translation.height)
                updateContentSplitPreview(tab.id, at: value.location)
                if tabDragIsOverContent { dragLayout = nil; updateFolderDropSlot(nil); return }
                updateFolderHover(at: value.location)
                refreshDragLayout(for: tab, at: value.location)
            }
            .onEnded { value in
                guard model.coordinator.commandBar == nil, model.renamingTabID == nil,
                      dragSourceItem?.id == tab.id else { endDrag(); return }
                dragPoint = value.location
                dragTranslation = CGSize(width: tab.isFavorite ? value.translation.width : 0, height: value.translation.height)
                updateContentSplitPreview(tab.id, at: value.location)
                if tabDragIsOverContent {
                    _ = model.commitSplitPreview()
                    // Splitting never changes the sidebar organization and has
                    // no placement haptic or cross-section landing animation.
                    // Releasing between/outside the cards cancels, never reorders.
                    endDrag()
                    return
                }
                updateFolderHover(at: value.location)
                guard let destination = destinationSection(at: value.location) else { finishDrag(item: .tab(tab)); return }
                refreshDragLayout(for: tab, at: value.location)
                let folderID = destination == .pinned ? dropFolder : nil
                let insertion = dragLayout?.insertion(at: value.location)
                guard dragLayout != nil, insertion != nil || destination != section(of: tab) || folderID != tab.folderID else {
                    finishDrag(item: .tab(tab)); return
                }
                finishDrag(item: .tab(tab), destination: destination, folderID: folderID) {
                    model.placeTab(tab.id, in: destination, folderID: folderID, before: insertion?.before)
                }
            }
    }

    func surfaceFrame(_ name: String) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: BrowserSurfaceFrames.self,
                value: [name: geometry.frame(in: .named("browserWindow"))])
        }.allowsHitTesting(false)
    }

    func updateContentSplitPreview(_ tabID: UUID, at sidebarPoint: CGPoint) {
        let point = CGPoint(x: sidebarWindowFrame.minX + sidebarPoint.x, y: sidebarWindowFrame.minY + sidebarPoint.y)
        windowPointer.location = point
        model.updateSplitPreview(for: tabID, at: point, in: contentWindowFrame, leadingInset: splitDropLeadingInset)
    }

    var receivingFavorite: Bool {
        guard dragSourceItem != nil, let draggingTab, let tab = model.coordinator.tabStore.tab(id: draggingTab),
              let destination = destinationSection(at: dragPoint) else { return false }
        return destination == .favorites && !tab.isFavorite
    }

    @ViewBuilder
    var crossSectionPreview: some View {
        if let item = dragSourceItem, dragLanding == nil, !tabDragIsOverContent {
            let section = previewSection(for: item)
            let frame = dragPreviewFrame(for: item, section: section)
            let overFavorites = section == .favorites
            dragItemPreview(item, section: section, size: frame.size, lifted: true)
                .animation(folderDragAnimation, value: section)
                .animation(folderDragAnimation, value: frame.width)
                .offset(x: overFavorites ? 0 : frame.midX)
                .animation(folderDragAnimation, value: overFavorites ? 0 : frame.midX)
                // Animate shape/container changes, never the pointer position.
                .position(x: overFavorites ? frame.midX : 0, y: frame.midY)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    @ViewBuilder
    var landingPreview: some View {
        if let landing = dragLanding {
            let frame = landing.motion.frame
            let settling = landing.motion.animationID != nil
            dragItemPreview(landing.item, section: settling ? landing.section : landing.releasedSection,
                size: frame.size, lifted: !settling)
                .position(x: frame.midX, y: frame.midY)
                .opacity(landing.motion.opacity)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    func previewSection(for item: SidebarDragItem) -> TabStore.Section {
        switch item {
        case .tab: destinationSection(at: dragPoint) ?? .regular
        case .folder: .pinned
        }
    }

    func dragPreviewFrame(for item: SidebarDragItem, section: TabStore.Section) -> CGRect {
        let bounds = dragRowBounds(at: dragPoint)
        let size: CGSize
        switch item {
        case .tab where section == .favorites:
            let favoriteBounds = dropAreas["favoriteContent"] ?? bounds
            let order = dragLayout?.grid == true ? dragLayout?.order(at: dragPoint) ?? [] : []
            let frames = SidebarReorderLayout.favoriteFrames(count: max(1, order.count), in: favoriteBounds)
            let width = order.firstIndex(of: item.id).map { frames[$0].width } ?? frames.first?.width ?? 54
            size = CGSize(width: width, height: SidebarReorderLayout.favoriteHeight)
        case .tab:
            size = CGSize(width: bounds.width, height: section == .pinned ? PinnedIsland.height : 32)
        case .folder:
            size = CGSize(width: bounds.width, height: dragSourceFrame.height)
        }
        let x: CGFloat
        if case .tab(let tab) = item, section == .favorites, tab.isFavorite {
            // Preserve an off-center grab within an existing tile. Centering it
            // under the pointer would itself cause a snap on pickup.
            x = dragSourceFrame.midX + dragTranslation.width
        } else {
            x = section == .favorites ? dragPoint.x : bounds.midX
        }
        return CGRect(x: x - size.width / 2, y: dragSourceFrame.midY + dragTranslation.height - size.height / 2,
                      width: size.width, height: size.height)
    }

    @ViewBuilder
    func dragItemPreview(_ item: SidebarDragItem, section: TabStore.Section, size: CGSize, lifted: Bool) -> some View {
        let overFavorites = section == .favorites
        let cornerRadius: CGFloat = overFavorites ? 9 : (section == .pinned ? PinnedIsland.cornerRadius : 7)
        switch item {
        case .tab(let tab):
            let name = tab.customTitle ?? tab.pinnedTitle ?? tab.pinnedURL?.host ?? tab.title
            Group {
                if overFavorites {
                    TabArtwork(tab: tab, store: model.webViews.favicons, page: model.webViews.pages[tab.id],
                               size: 18, monogram: String(name.prefix(1)).uppercased())
                        .padding(.horizontal, 8)
                } else {
                    // Reuse the actual row's icon, media slot, separator and
                    // title layout so pickup cannot change their spacing.
                    tabRowContent(tab, selected: model.coordinator.activeTabID == tab.id, requestsArtwork: false)
                }
            }
                .font(.body).lineLimit(1)
                .frame(width: size.width, height: size.height)
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
                .shadow(radius: lifted ? 5 : 0, y: lifted ? 2 : 0)
        case .folder(let folder):
            HStack(spacing: 4) {
                FolderIcon(isOpen: false, themeColor: folderTheme(folder), emblem: FolderEmblem(folder))
                    .frame(width: FolderIcon.width, height: FolderIcon.height)
                    .frame(width: PinnedIsland.iconControlWidth, height: PinnedIsland.height)
                Text(folder.name).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(.callout).padding(.leading, PinnedIsland.leadingInset).padding(.trailing, 8)
            .frame(width: size.width, height: size.height)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: PinnedIsland.cornerRadius))
            .shadow(radius: lifted ? 5 : 0, y: lifted ? 2 : 0)
        }
    }

    func dragRowBounds(at point: CGPoint) -> CGRect {
        let bounds = sectionFrames[false] ?? dropAreas["favorites"] ?? dragSourceFrame
        guard destinationSection(at: point) == .pinned,
              let parent = dropFolder,
              let header = itemFrame(parent) else { return bounds }
        // Match a child's inset inside this folder, including nested outlines.
        return CGRect(x: header.minX + 12, y: bounds.minY,
                      width: max(1, header.width - 16), height: bounds.height)
    }

    func dropArea(_ key: String) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: SidebarFrames.self, value: [.dropArea(key): geometry.frame(in: .named("sidebarReordering"))])
        }.allowsHitTesting(false)
    }

    func section(of tab: BrowserTab) -> TabStore.Section {
        tab.isFavorite ? .favorites : (tab.pinnedURL == nil ? .regular : .pinned)
    }

    func needsPinInsertionSpace(in parent: UUID?) -> Bool {
        guard dragSourceItem != nil, let source = draggingTab, destinationSection(at: dragPoint) == .pinned,
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

    func destinationSection(at point: CGPoint) -> TabStore.Section? {
        if !model.isPrivate, (!model.favorites.isEmpty || revealDropSections), dropAreas["favorites"]?.contains(point) == true { return .favorites }
        guard let viewport = sectionFrames[false], viewport.contains(point),
              let regular = dropAreas["regular"] else { return nil }
        return model.isPrivate || point.y >= regular.minY ? .regular : .pinned
    }

    func groupPanel(active: Bool, dashed: Bool = false, isFolder: Bool = false) -> some View {
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

    func refreshFolderPanelHover() {
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

    func folderGroupFrame(_ id: UUID) -> CGRect? {
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

    func isDropAncestor(_ id: UUID) -> Bool {
        var current = dropFolder ?? pendingFolder
        var seen: Set<UUID> = []
        while let folder = current, seen.insert(folder).inserted {
            if folder == id { return true }
            current = model.coordinator.folders.first(where: { $0.id == folder })?.parentID
        }
        return false
    }

    enum FolderBoundary: Hashable {
        case header(UUID), end(UUID)
    }

    struct FolderBoundaries: PreferenceKey {
        static let defaultValue: [FolderBoundary: Anchor<CGRect>] = [:]
        static func reduce(value: inout [FolderBoundary: Anchor<CGRect>],
                           nextValue: () -> [FolderBoundary: Anchor<CGRect>]) {
            value.merge(nextValue(), uniquingKeysWith: { _, new in new })
        }
    }

    struct FolderPanel: Identifiable {
        let id: UUID
        let frame: CGRect
    }

    struct FolderBounceDrawing: ViewModifier {
        @Environment(\.folderBounceDisplacement) private var displacement
        let frame: CGRect
        let affected: Bool

        func body(content: Content) -> some View {
            content
                .frame(width: frame.width, height: frame.height + (affected ? displacement : 0))
                .offset(x: frame.minX, y: frame.minY)
        }
    }

    func pinnedGroupBackgrounds(anchors: [FolderBoundary: Anchor<CGRect>]) -> some View {
        GeometryReader { geometry in
            let visible = Set(pinnedOutline.filter(\.isFolder).map(\.id))
            let panels = model.coordinator.folders.compactMap { folder -> FolderPanel? in
                guard visible.contains(folder.id), folder.id != hiddenDragItemID,
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
            folderPanelBackgrounds(panels, affected: affected, size: geometry.size)
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

    func folderPanelBackgrounds(_ panels: [FolderPanel], affected: Set<UUID>,
                                        size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
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

    func previewOffset(_ id: UUID) -> CGSize {
        guard let draggingTab, dragSourceItem != nil else { return .zero }
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

    func vacatesSourceRow(_ item: SidebarItem) -> Bool {
        guard dragSourceItem != nil else { return false }
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

    func insertionOverflow(at y: CGFloat) -> CGFloat {
        guard draggingTab != nil, let dragLayout, dragLayout.foreign, !dragLayout.grid,
              destinationSection(at: dragPoint) == .regular,
              dragLayout.bounds.contains(dragPoint),
              let placeholder = dragLayout.slots.first(where: { $0.id == dragLayout.source }) else { return 0 }
        let bottom = dragLayout.slots.filter { $0.id != dragLayout.source }.last?.frame.maxY
            ?? placeholder.frame.minY - 4
        return y > bottom ? placeholder.frame.height + 4 : 0
    }

    struct RenameTabSheet: View {
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
            .browserReducedMotion()
            .onAppear { focused = true }
        }
    }
}
