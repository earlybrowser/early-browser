// SPDX-License-Identifier: MPL-2.0

import EarlyCore
import SwiftUI

extension BrowserSpace.Color {
    var tint: SwiftUI.Color {
        swatch.color
    }
}

extension SpaceThemeRGB {
    var color: SwiftUI.Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
}

struct SpaceActions: View {
    let model: BrowserWindowModel
    let space: BrowserSpace

    var body: some View {
        Button("Edit Space…") { model.requestEditSpace(space.id) }
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

    var body: some View {
        HStack(spacing: 8) {
            // Reserved until the real downloads service is implemented.
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.tertiary)
                .frame(width: 28, height: 28)
                .accessibilityLabel("Downloads, not available yet")
                .help("Downloads (not available yet)")
            indicatorStrip
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
            .buttonStyle(SpaceControlStyle())
            .accessibilityLabel("New Space")
            .accessibilityIdentifier("space.new")
            .help("New Space")
            .disabled(!model.canManageSpaces)
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

    private var indicatorStrip: some View {
        GeometryReader { geometry in
            let spaces = model.coordinator.spaces
            let layout = SpaceNavigation.footerLayout(count: spaces.count, current: model.activeSpaceIndex,
                progress: reduceMotion ? 0 : model.spaceSwipeProgress, width: geometry.size.width)
            let contentWidth = Double(spaces.count) * SpaceNavigation.footerItemWidth
            HStack(spacing: 0) {
                ForEach(Array(spaces.enumerated()), id: \.element.id) { index, space in
                    spaceDot(space, index: index)
                        .disabled(!layout.visibleRange.contains(index))
                        .accessibilityHidden(!layout.visibleRange.contains(index))
                }
            }
            .frame(width: contentWidth, height: 32, alignment: .leading)
            .offset(x: -layout.offset)
            .frame(width: layout.width, height: 32, alignment: .leading)
            .clipped()
            .contentShape(Rectangle())
            .mask {
                let fade = min(0.12, 8 / max(1, layout.width))
                LinearGradient(stops: [
                    .init(color: layout.offset > 0 ? .clear : .black, location: 0),
                    .init(color: .black, location: fade),
                    .init(color: .black, location: 1 - fade),
                    .init(color: layout.offset + layout.width < contentWidth ? .clear : .black, location: 1)
                ], startPoint: .leading, endPoint: .trailing)
            }
            .frame(width: geometry.size.width, height: 32)
        }
        .frame(height: 32)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Space switcher")
        .accessibilityIdentifier("space.strip")
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.20), value: model.coordinator.activeSpaceID)
        .transaction { $0.disablesAnimations = reduceMotion }
    }

    private func spaceDot(_ space: BrowserSpace, index: Int) -> some View {
        let selected = space.id == model.coordinator.activeSpaceID
        let fill = SpaceNavigation.indicatorFill(index: index, current: model.activeSpaceIndex,
            count: model.coordinator.spaces.count, progress: reduceMotion ? 0 : model.spaceSwipeProgress)
        return Button { _ = model.switchSpace(to: space.id) } label: {
            SpaceIconView(icon: space.icon)
                .opacity((contrast == .increased ? 0.65 : 0.35) + (contrast == .increased ? 0.35 : 0.65) * fill)
                .frame(width: SpaceNavigation.footerItemWidth, height: 28)
                .contentShape(Rectangle())
                .overlay {
                    if focusedSpace == space.id {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.6), lineWidth: 2)
                    }
                }
        }
        .buttonStyle(SpaceControlStyle())
        .focused($focusedSpace, equals: space.id)
        .disabled(!model.canManageSpaces)
        .accessibilityLabel(space.name)
        .accessibilityValue("\(selected ? "Current Space" : "Switch Space") · \(space.icon?.accessibilityName ?? "Default dot")")
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

/// Swipes briefly lock controls while settling. Keep their colors unchanged
/// during that lock instead of PlainButtonStyle's dim/restore flash.
private struct SpaceControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
    }
}

private struct SpaceEditorSheet: View {
    let model: BrowserWindowModel
    let request: BrowserWindowModel.SpaceEditor
    @State private var name: String
    @State private var color: BrowserSpace.Color
    @State private var icon: SpaceIcon?
    @State private var showingIconPicker = false
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
        _icon = State(initialValue: existing?.icon)
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
            HStack(spacing: 12) {
                Button { showingIconPicker.toggle() } label: {
                    SpaceIconView(icon: icon, size: 15)
                        .frame(width: 38, height: 38)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.12)) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose Space icon")
                .accessibilityValue(icon?.accessibilityName ?? "Default dot")
                .accessibilityIdentifier("space.iconPicker")
                .popover(isPresented: $showingIconPicker, arrowEdge: .bottom) {
                    SpaceIconPicker(selection: $icon) { showingIconPicker = false }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Space icon")
                    Text("Optional. A small dot is used by default.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Theme color")
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
            if let id = model.createSpace(name: name, color: color, icon: icon) {
                _ = model.switchSpace(to: id)
                success = true
            } else { success = false }
        case .edit(let id): success = model.editSpace(id, name: name, color: color, icon: icon)
        }
        if success { model.spaceEditor = nil }
        else { error = "Could not save this Space. It may have been removed in another window." }
    }
}
