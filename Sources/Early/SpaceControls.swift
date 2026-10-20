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

/// Original Early download artwork, shared with the website's download icons.
/// Keep the 24-point geometry in sync with web/features-data.js and web/index.html.
struct DownloadGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(x: 3, y: 3, width: 18, height: 18))
        path.move(to: CGPoint(x: 12, y: 7.25))
        path.addLine(to: CGPoint(x: 12, y: 13.5))
        path.move(to: CGPoint(x: 9.25, y: 10.75))
        path.addLine(to: CGPoint(x: 12, y: 13.5))
        path.addLine(to: CGPoint(x: 14.75, y: 10.75))
        path.move(to: CGPoint(x: 8, y: 14.25))
        path.addLine(to: CGPoint(x: 8, y: 15.5))
        path.addQuadCurve(to: CGPoint(x: 9.75, y: 17.25), control: CGPoint(x: 8, y: 17.25))
        path.addLine(to: CGPoint(x: 14.25, y: 17.25))
        path.addQuadCurve(to: CGPoint(x: 16, y: 15.5), control: CGPoint(x: 16, y: 17.25))
        path.addLine(to: CGPoint(x: 16, y: 14.25))
        let scale = min(rect.width, rect.height) / 24
        return path.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                               tx: rect.midX - 12 * scale,
                                               ty: rect.midY - 12 * scale))
    }
}

struct SpaceActions: View {
    let model: BrowserWindowModel
    let space: BrowserSpace

    var body: some View {
        Button("Edit Space…") { model.perform(.editSpace(space.id)) }
        Button("Duplicate Space") { model.perform(.duplicateSpace(space.id)) }
        Button("Delete Space…", role: .destructive) { model.perform(.deleteSpace(space.id)) }
            .disabled(model.coordinator.spaces.count <= 1)
    }
}

struct SpaceFooter: View {
    @Bindable var model: BrowserWindowModel
    @FocusState private var focusedSpace: UUID?
    @State private var spaceDrag: SpaceReorderDrag?
    @GestureState private var spaceDragGestureActive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 8) {
            // Reserved until the real downloads service is implemented.
            DownloadGlyph()
                .stroke(style: StrokeStyle(lineWidth: 1.75 * 18 / 24, lineCap: .round, lineJoin: .round))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .frame(width: 28, height: 28)
                .accessibilityLabel("Downloads, not available yet")
                .help("Downloads (not available yet)")
            indicatorStrip
            Button { model.perform(.newSpace) } label: {
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
        .task(id: spaceDrag?.source) {
            while !Task.isCancelled, spaceDrag != nil {
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
                guard var preview = spaceDrag else { return }
                let previous = preview.destinationIndex
                if preview.autoScrollStep() {
                    spaceDrag = preview
                    if previous != preview.destinationIndex { signalReorder() }
                }
            }
        }
        .onChange(of: spaceDragGestureActive) { _, active in
            if !active { cancelSpaceDrag() }
        }
        .onChange(of: model.coordinator.spaces.map(\.id)) { _, ids in
            if let spaceDrag, spaceDrag.ids != ids { cancelSpaceDrag() }
        }
        .onChange(of: model.coordinator.activeSpaceID) { cancelSpaceDrag() }
        .onChange(of: model.sidebarIsHidden) { _, hidden in
            if hidden { cancelSpaceDrag() }
        }
        .onDisappear { cancelSpaceDrag() }
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
            let viewport = spaceDrag?.width ?? layout.width
            let offset = spaceDrag?.viewportOffset ?? layout.offset
            HStack(spacing: 0) {
                ForEach(Array(spaces.enumerated()), id: \.element.id) { index, space in
                    let visible = spaceDrag?.isVisible(space.id) ?? layout.visibleRange.contains(index)
                    let translation = spaceDrag?.offset(for: space.id) ?? 0
                    spaceDot(space, index: index)
                        .offset(x: translation)
                        .animation(reduceMotion || spaceDrag?.source == space.id ? nil : .easeInOut(duration: 0.14), value: translation)
                        .zIndex(spaceDrag?.source == space.id ? 1 : 0)
                        .highPriorityGesture(reordering(space.id, width: layout.width, offset: layout.offset))
                        .frame(width: SpaceNavigation.footerItemWidth, height: 28)
                        .disabled(!visible)
                        .accessibilityHidden(!visible)
                }
            }
            // Own the viewport's accessibility geometry here. Without this
            // inner boundary, SwiftUI can give the first button the entire
            // strip's frame, sending clicks/drags to a neighboring Space.
            .accessibilityElement(children: .contain)
            .frame(width: contentWidth, height: 32, alignment: .leading)
            .offset(x: -offset)
            .frame(width: viewport, height: 32, alignment: .leading)
            .clipped()
            .contentShape(Rectangle())
            .coordinateSpace(name: "spaceReordering")
            .mask {
                let fade = min(0.12, 8 / max(1, viewport))
                LinearGradient(stops: [
                    .init(color: offset > 0 ? .clear : .black, location: 0),
                    .init(color: .black, location: fade),
                    .init(color: .black, location: 1 - fade),
                    .init(color: offset + viewport < contentWidth ? .clear : .black, location: 1)
                ], startPoint: .leading, endPoint: .trailing)
            }
            .frame(width: geometry.size.width, height: 32)
            .onChange(of: layout.width) { cancelSpaceDrag() }
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
        return Button {
            guard spaceDrag == nil else { return }
            model.perform(.switchSpace(space.id))
        } label: {
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
        .disabled(!model.canManageSpaces && spaceDrag == nil)
        .accessibilityLabel(space.name)
        .accessibilityValue("\(selected ? "Current Space" : "Switch Space") · \(space.icon?.accessibilityName ?? "Default dot")")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("space.\(space.id)")
        .accessibilityHint("Drag horizontally to reorder, or use the Move Left and Move Right actions.")
        .accessibilityAction(named: Text("Move Left")) { _ = model.shiftSpace(space.id, by: -1) }
        .accessibilityAction(named: Text("Move Right")) { _ = model.shiftSpace(space.id, by: 1) }
        .help(space.name)
        .contextMenu {
            SpaceActions(model: model, space: space)
            Divider()
            Button("New Space…") { model.perform(.newSpace) }
        }
    }

    private func reordering(_ id: UUID, width: Double, offset: Double) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("spaceReordering"))
            .updating($spaceDragGestureActive) { _, active, _ in active = true }
            .onChanged { value in
                if spaceDrag == nil {
                    guard model.canManageSpaces,
                          abs(value.translation.width) > abs(value.translation.height) * 1.2,
                          let preview = SpaceReorderDrag(ids: model.coordinator.spaces.map(\.id), source: id,
                              width: width, viewportOffset: offset, startX: value.startLocation.x) else { return }
                    model.cancelSpaceSwipePresentation()
                    spaceDrag = preview
                    model.sidebarInteractionInProgress = true
                    signalReorder()
                }
                guard var preview = spaceDrag, preview.source == id else { return }
                let crossed = preview.update(pointerX: value.location.x, pointerY: value.location.y)
                spaceDrag = preview
                if crossed { signalReorder() }
            }
            .onEnded { value in
                guard var preview = spaceDrag, preview.source == id else { return }
                preview.update(pointerX: value.location.x, pointerY: value.location.y)
                let canCommit = preview.canDrop && preview.hasMoved && preview.ids == model.coordinator.spaces.map(\.id)
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                    spaceDrag = nil
                    model.sidebarInteractionInProgress = false
                    if canCommit, model.reorderSpace(id, before: preview.beforeID) { signalReorder() }
                }
            }
    }

    private func cancelSpaceDrag() {
        guard spaceDrag != nil else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
            spaceDrag = nil
            model.sidebarInteractionInProgress = false
        }
    }

    private func signalReorder() { BrowserHaptics.alignment(enabled: model.preferences.haptics) }
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
    @State private var profileID: UUID
    @State private var confirmingProfileMove = false
    @State private var showingIconPicker = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    init(model: BrowserWindowModel, request: BrowserWindowModel.SpaceEditor) {
        self.model = model
        self.request = request
        let existing: BrowserSpace?
        if case .edit(let id, _) = request { existing = model.coordinator.spaces.first { $0.id == id } }
        else { existing = nil }
        _name = State(initialValue: existing?.name ?? "")
        _color = State(initialValue: existing?.color ?? .blue)
        _icon = State(initialValue: existing?.icon)
        _profileID = State(initialValue: model.coordinator.profileID)
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
            if case .edit = request, let application = model.application {
                Picker("Profile", selection: $profileID) {
                    ForEach(application.profiles) { profile in Text(profile.name).tag(profile.id) }
                }
                .accessibilityIdentifier("space.profile")
                Text(profileID == model.coordinator.profileID
                     ? "Spaces in this profile share its cookies and logins."
                     : "Moving to another profile reloads this Space’s pages. Logins and Favorites are not transferred.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
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
        .alert("Move Space to another profile?", isPresented: $confirmingProfileMove) {
            Button("Cancel", role: .cancel) {}
            Button("Move and Reload") { save(confirmedMove: true) }
        } message: {
            Text("This moves its tabs and folders in every window and reloads open pages with the destination profile’s website data. Unsaved page changes may be lost. Closed pins stay closed, and Favorites stay in the original profile.")
        }
    }

    private var title: String {
        switch request { case .new: "New Space"; case .edit: "Edit Space" }
    }

    private func save(confirmedMove: Bool = false) {
        guard model.spaceEditor != nil, BrowserSpace.normalizedName(name) != nil else { return }
        if profileID != model.coordinator.profileID && !confirmedMove {
            confirmingProfileMove = true
            return
        }
        let success: Bool
        switch request {
        case .new:
            if let id = model.createSpace(name: name, color: color, icon: icon) {
                _ = model.switchSpace(to: id)
                success = true
            } else { success = false }
        case .edit(let id, let selectOnSave):
            if profileID != model.coordinator.profileID {
                success = model.application?.moveSpace(id, from: model, to: profileID, name: name, color: color, icon: icon) == true
            } else { success = model.editSpace(id, name: name, color: color, icon: icon, selectOnSave: selectOnSave) }
        }
        if success { model.spaceEditor = nil }
        else { error = "Could not save this Space. It may have been removed in another window." }
    }
}
