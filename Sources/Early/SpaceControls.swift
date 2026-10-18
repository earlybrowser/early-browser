import EarlyCore
import SwiftUI

extension BrowserSpace.Color {
    var tint: SwiftUI.Color {
        switch self {
        case .gray: .gray
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        }
    }
}

struct SpaceActions: View {
    let model: BrowserWindowModel
    let space: BrowserSpace

    var body: some View {
        Button("Rename Space…") { model.requestEditSpace(space.id) }
        Button("Duplicate Space") { model.duplicateAndSelectSpace(space.id) }
        Button("Delete Space…", role: .destructive) { model.requestDeleteSpace(space.id) }
            .disabled(model.coordinator.spaces.count <= 1)
    }
}

struct SpaceFooter: View {
    @Bindable var model: BrowserWindowModel
    @FocusState private var focusedSpace: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var visibleRange: Range<Int> {
        SpaceNavigation.footerRange(count: model.coordinator.spaces.count,
            activeIndex: model.activeSpaceIndex, width: model.sidebarWidth)
    }

    var body: some View {
        ZStack {
            HStack {
                // Reserved until the real downloads service is implemented.
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 28)
                    .accessibilityLabel("Downloads, not available yet")
                    .help("Downloads (not available yet)")
                Spacer(minLength: 0)
                Button { model.requestNewSpace() } label: {
                    Image(systemName: "plus").frame(width: 28, height: 28)
                        .overlay {
                            if model.spaceSwipeCreationProgress > 0 {
                                Circle().trim(from: 0, to: model.spaceSwipeCreationProgress)
                                    .stroke(Color.primary.opacity(0.55), lineWidth: 1.5)
                                    .padding(1).rotationEffect(.degrees(-90))
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New Space")
                .accessibilityIdentifier("space.new")
                .help("New Space")
                .disabled(!model.canManageSpaces)
            }
            HStack(spacing: 2) {
                ForEach(Array(model.coordinator.spaces.enumerated()).filter { visibleRange.contains($0.offset) }, id: \.element.id) { _, space in
                    spaceDot(space)
                }
                if visibleRange.count < model.coordinator.spaces.count {
                    Menu {
                        ForEach(model.coordinator.spaces) { space in
                            Button {
                                _ = model.switchSpace(to: space.id)
                            } label: {
                                Label(space.name, systemImage: space.id == model.coordinator.activeSpaceID ? "checkmark.circle.fill" : "circle")
                            }
                        }
                        Divider()
                        if let space = model.coordinator.activeSpace { SpaceActions(model: model, space: space) }
                        Button("New Space…") { model.requestNewSpace() }
                    } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("More Spaces")
                    .accessibilityIdentifier("space.overflow")
                    .help("All Spaces and Space actions")
                    .disabled(!model.canManageSpaces)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.coordinator.activeSpaceID)
        }
        .frame(height: 32)
        .padding(.horizontal, 6)
        .padding(.top, 10)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottomTrailing) {
            if model.spaceSwipeCreationProgress >= 1 {
                Text("Release to create a Space")
                    .font(.caption).padding(8)
                    .background {
                        if reduceTransparency || contrast == .increased {
                            RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor))
                        } else { RoundedRectangle(cornerRadius: 8).fill(.thickMaterial) }
                    }
                    .offset(y: -42)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spaces")
        .accessibilityIdentifier("sidebar.footer")
        .sheet(item: $model.spaceEditor, onDismiss: { model.activateSelection() }) { request in
            SpaceEditorSheet(model: model, request: request)
        }
        .alert("Delete \(deletingSpaceName)?", isPresented: Binding(
            get: { model.spaceDeletionID != nil },
            set: { if !$0 { model.spaceDeletionID = nil } }
        ), presenting: deletingSpace) { space in
            Button("Cancel", role: .cancel) { model.spaceDeletionID = nil }
            Button("Delete Space", role: .destructive) {
                model.spaceDeletionID = nil
                if !model.deleteSpace(space.id) { model.notice = "This Space could not be deleted." }
            }
        } message: { _ in
            Text("This deletes its tabs, pins, folders, and closed-tab history in every window. Favorites are kept. This cannot be undone.")
        }
    }

    private var deletingSpaceName: String {
        deletingSpace?.name ?? "Space"
    }

    private var deletingSpace: BrowserSpace? { model.coordinator.spaces.first { $0.id == model.spaceDeletionID } }

    private func spaceDot(_ space: BrowserSpace) -> some View {
        let selected = space.id == model.coordinator.activeSpaceID
        return Button { _ = model.switchSpace(to: space.id) } label: {
            Circle().fill(space.color.tint)
                .saturation(selected ? 1 : 0.5)
                .frame(width: 16, height: 16)
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
                .overlay {
                    if focusedSpace == space.id {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.6), lineWidth: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .focused($focusedSpace, equals: space.id)
        .disabled(!model.canManageSpaces)
        .accessibilityLabel(space.name)
        .accessibilityValue(selected ? "Current Space" : "Switch Space")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("space.\(space.id)")
        .help(space.name)
        .contextMenu {
            SpaceActions(model: model, space: space)
            Divider()
            Button("New Space…") { model.requestNewSpace() }
        }
    }
}

private struct SpaceEditorSheet: View {
    let model: BrowserWindowModel
    let request: BrowserWindowModel.SpaceEditor
    @State private var name: String
    @State private var color: BrowserSpace.Color
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    init(model: BrowserWindowModel, request: BrowserWindowModel.SpaceEditor) {
        self.model = model
        self.request = request
        let existing: BrowserSpace?
        if case .edit(let id) = request { existing = model.coordinator.spaces.first { $0.id == id } }
        else { existing = nil }
        _name = State(initialValue: existing?.name ?? "")
        _color = State(initialValue: existing?.color ?? .blue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            TextField("Space name", text: $name)
                .focused($nameFocused).accessibilityIdentifier("space.name")
                .onSubmit { save() }
            if !name.isEmpty, BrowserSpace.normalizedName(name) == nil {
                Text("Use a name with 1–64 characters and no line breaks.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Color")
                    Spacer()
                    Text(color.rawValue.capitalized).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    ForEach(BrowserSpace.Color.allCases, id: \.self) { option in
                        Button { color = option } label: {
                            Circle().fill(option.tint)
                                .frame(width: 22, height: 22)
                                .overlay {
                                    if color == option {
                                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 1)
                                    }
                                }
                                .frame(width: 28, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.rawValue.capitalized)
                        .accessibilityAddTraits(color == option ? .isSelected : [])
                        .accessibilityIdentifier("space.color.\(option.rawValue)")
                        .help(option.rawValue.capitalized)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("space.color")
            if let error { Text(error).font(.callout).foregroundStyle(.secondary) }
            HStack {
                Button("Cancel") { model.spaceEditor = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(BrowserSpace.normalizedName(name) == nil)
            }
        }
        .padding(24).frame(width: 340)
        .task { await Task.yield(); nameFocused = true }
    }

    private var title: String {
        switch request { case .new: "New Space"; case .edit: "Edit Space" }
    }

    private func save() {
        guard model.spaceEditor != nil, BrowserSpace.normalizedName(name) != nil else { return }
        let success: Bool
        switch request {
        case .new:
            if let id = model.createSpace(name: name, color: color) {
                _ = model.switchSpace(to: id)
                success = true
            } else { success = false }
        case .edit(let id): success = model.editSpace(id, name: name, color: color)
        }
        if success { model.spaceEditor = nil }
        else { error = "Could not save this Space. It may have been removed in another window." }
    }
}

/// A non-interactive neighboring page during a swipe. Read cached artwork and
/// saved organization only: previewing must never fetch icons or load web pages.
struct SpaceSidebarPreview: View {
    let model: BrowserWindowModel
    let space: BrowserSpace

    private var selectedTab: UUID? { model.coordinator.session.selectionBySpace[space.id] }

    private enum Item: Identifiable {
        case bookend(String), divider, newTab
        case tab(BrowserTab, Int), folder(BrowserFolder, Int), folderEnd(UUID)

        var id: String {
            switch self {
            case .bookend(let name): name
            case .divider: "divider"
            case .newTab: "new-tab"
            case .tab(let tab, _): "tab-\(tab.id)"
            case .folder(let folder, _): "folder-\(folder.id)"
            case .folderEnd(let id): "folder-end-\(id)"
            }
        }
    }

    private func folderItems(parent: UUID? = nil, depth: Int = 0) -> [Item] {
        guard depth <= 32 else { return [] }
        return model.coordinator.tabStore.pinnedItems(in: space.id, parentID: parent).flatMap { item -> [Item] in
            switch item {
            case .tab(let tab): return [.tab(tab, depth)]
            case .folder(let folder):
                let children = folder.isExpanded ? folderItems(parent: folder.id, depth: depth + 1) : []
                return [.folder(folder, depth)] + children + (children.isEmpty ? [] : [.folderEnd(folder.id)])
            }
        }
    }

    private var items: [Item] {
        let pins = folderItems()
        return (pins.isEmpty ? [] : [.bookend("pinned-start")] + pins + [.bookend("pinned-end")])
            + [.divider, .newTab]
            + model.coordinator.tabStore.todayTabs(in: space.id).map { .tab($0, 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(space.name).font(.callout.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 8)
            ScrollView {
                // Match the live sidebar's fonts, row heights, nesting and end
                // spacers so settling the swipe never changes the layout.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        row(item).padding(.bottom, item.id == items.last?.id ? 0 : 4)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false).accessibilityHidden(true)
    }

    @ViewBuilder private func row(_ item: Item) -> some View {
        switch item {
        case .bookend: Color.clear.frame(height: 4)
        case .folderEnd: Color.clear.frame(height: 6)
        case .divider: Divider().padding(.vertical, 8)
        case .newTab:
            HStack {
                Label("New Tab", systemImage: "plus")
                Spacer()
                Text("⌘T").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
        case .folder(let folder, let depth):
            HStack(spacing: 6) {
                FolderIcon(isOpen: folder.isExpanded)
                    .frame(width: 19, height: 20).padding(.vertical, 7)
                HStack {
                    Text(folder.name).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(height: 34)
            }
            .padding(.horizontal, 6)
            .padding(.leading, CGFloat(min(depth, 8)) * 12)
            .padding(.trailing, CGFloat(min(depth, 8)) * 4)
        case .tab(let tab, let depth):
            HStack(spacing: tab.hasNavigatedFromPin ? 1 : 4) {
                if tab.pinnedURL != nil {
                    artwork(tab).font(.system(size: 13, weight: .medium))
                        .frame(width: 34, height: 34)
                }
                HStack(spacing: tab.hasNavigatedFromPin ? 3 : 8) {
                    if tab.pinnedURL == nil { artwork(tab) }
                    if tab.hasNavigatedFromPin { Text("/").foregroundStyle(.tertiary) }
                    if model.webViews.pages[tab.id]?.isPlayingMedia == true {
                        Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(tab.displayTitle).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
            }
            .foregroundStyle(tab.isOpen ? .primary : .secondary)
            .padding(.leading, tab.pinnedURL == nil ? 8 : 0).padding(.trailing, 8)
            .background(Color.primary.opacity(tab.id == selectedTab ? 0.08 : 0),
                        in: RoundedRectangle(cornerRadius: tab.pinnedURL == nil ? 7 : 10))
            .padding(.leading, CGFloat(min(depth, 8)) * 12)
            .padding(.trailing, CGFloat(min(depth, 8)) * 4)
        }
    }

    @ViewBuilder private func artwork(_ tab: BrowserTab) -> some View {
        if let image = model.webViews.favicons.image(for: tab.pinnedURL ?? tab.currentURL) {
            Image(nsImage: image).resizable().scaledToFit().frame(width: 16, height: 16)
        } else {
            Image(systemName: tab.pinnedURL == nil ? "globe" : "pin").frame(width: 16, height: 16)
        }
    }
}
