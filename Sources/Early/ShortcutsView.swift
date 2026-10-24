// SPDX-License-Identifier: MPL-2.0

import AppKit
import EarlyCore
import SwiftUI

extension BrowserShortcut {
    /// The menu's form of it.
    var keyboardShortcut: KeyboardShortcut? {
        let key: KeyEquivalent? = switch self.key {
        case "leftArrow": .leftArrow
        case "rightArrow": .rightArrow
        case "upArrow": .upArrow
        case "downArrow": .downArrow
        case "tab": .tab
        case "space": .space
        case "return": .return
        case "delete": .delete
        case "forwardDelete": .deleteForward
        case "home": .home
        case "end": .end
        case "pageUp": .pageUp
        case "pageDown": .pageDown
        default:
            if isFunctionKey, let number = Int(self.key.dropFirst()), let scalar = UnicodeScalar(NSF1FunctionKey + number - 1) {
                KeyEquivalent(Character(scalar))
            } else if self.key.count == 1, let character = self.key.first {
                KeyEquivalent(character)
            } else {
                nil
            }
        }
        guard let key else { return nil }
        var flags: EventModifiers = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return KeyboardShortcut(key, modifiers: flags)
    }

    /// What was typed while recording, or nil for a key that can't be one
    /// (modifiers alone, Escape).
    init?(event: NSEvent) {
        let named: [UInt16: String] = [123: "leftArrow", 124: "rightArrow", 126: "upArrow", 125: "downArrow", 48: "tab",
                                       49: "space", 36: "return", 76: "return", 51: "delete", 117: "forwardDelete",
                                       115: "home", 119: "end", 116: "pageUp", 121: "pageDown",
                                       122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7",
                                       100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12"]
        let key: String
        if let name = named[event.keyCode] {
            key = name
        } else if event.keyCode == 53 {
            return nil
        } else if let character = event.characters(byApplyingModifiers: [])?.lowercased(), character.count == 1,
                  let scalar = character.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar) {
            key = character
        } else {
            return nil
        }
        var modifiers: Modifiers = []
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        self.init(key, modifiers)
    }
}

extension BrowserPreferences {
    /// The command's shortcut for a menu item; nil when it has none.
    func keyboardShortcut(_ command: BrowserCommand) -> KeyboardShortcut? {
        shortcuts.shortcut(for: command)?.keyboardShortcut
    }

    /// " (⌘T)" for a tooltip, or nothing when the command has no shortcut.
    func shortcutHint(_ command: BrowserCommand) -> String {
        shortcuts.shortcut(for: command).map { " (\($0.display))" } ?? ""
    }
}

/// Settings › Shortcuts: each command's shortcut, which can be changed,
/// removed or reset. Numbered tabs and Spaces, Control-Tab and macOS's own
/// shortcuts can't be taken.
struct ShortcutsSettingsSection: View {
    @Bindable var preferences: BrowserPreferences
    @State private var recording: BrowserCommand?
    @State private var problem: (command: BrowserCommand, message: String)?
    @State private var conflict: Conflict?
    @State private var search = ""

    struct Conflict: Identifiable {
        let shortcut: BrowserShortcut
        let command: BrowserCommand
        let owner: BrowserCommand
        var id: String { "\(command.rawValue)-\(owner.rawValue)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard {
                Label("Keyboard shortcuts", systemImage: "keyboard").font(.callout.weight(.medium))
                Text("Click a shortcut, then press the keys you want. Use Command or Control with a key. Press Delete to remove a shortcut, or Escape to keep it.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                TextField("Search shortcuts", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("shortcuts.search")
                Button("Restore Defaults") {
                    recording = nil
                    preferences.shortcuts.resetAll()
                }
                .disabled(!preferences.shortcuts.hasChanges)
                .accessibilityIdentifier("shortcuts.restoreDefaults")
            }
            ForEach(BrowserCommand.Group.allCases, id: \.self) { group in
                let commands = group.commands.filter(matches)
                if !commands.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        SettingsCard {
                            ForEach(Array(commands.enumerated()), id: \.element) { index, command in
                                if index > 0 { Divider() }
                                row(command)
                            }
                        }
                    }
                }
            }
            Text("Select Tab 1–9 (⌘1–⌘9), Spaces 1–9 (⌥⌘1–⌥⌘9) and the tab switcher (⌃Tab) keep their shortcuts.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .background(ShortcutRecorder(recording: $recording) { shortcut in finish(shortcut) })
        .alert("Use \(conflict?.shortcut.display ?? "") for “\(conflict?.command.title ?? "")”?",
               isPresented: Binding(get: { conflict != nil }, set: { if !$0 { conflict = nil } }), presenting: conflict) { conflict in
            Button("Use for \(conflict.command.title)") {
                preferences.shortcuts.assign(conflict.shortcut, to: conflict.command, replacing: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: { conflict in
            Text("\(conflict.owner.title) uses it now and will have no shortcut.")
        }
        .onDisappear { recording = nil }
    }

    private func matches(_ command: BrowserCommand) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return command.title.localizedCaseInsensitiveContains(query)
            || preferences.shortcuts.shortcut(for: command)?.display.localizedCaseInsensitiveContains(query) == true
    }

    private func row(_ command: BrowserCommand) -> some View {
        let shortcut = preferences.shortcuts.shortcut(for: command)
        let isRecording = recording == command
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(command.title)
                Spacer(minLength: 8)
                if preferences.shortcuts.isChanged(command) {
                    Button {
                        if let problem = preferences.shortcuts.reset(command) { self.problem = (command, problem.message) }
                    } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .help(command.defaultShortcut.map { "Restore \($0.display)" } ?? "Restore: no shortcut")
                    .accessibilityLabel("Restore \(command.title)’s shortcut")
                }
                Button {
                    problem = nil
                    recording = isRecording ? nil : command
                } label: {
                    Text(isRecording ? "Type shortcut…" : shortcut?.display ?? "None")
                        .font(.system(.callout, design: .rounded).weight(.medium))
                        .foregroundStyle(isRecording ? AnyShapeStyle(.tint) : shortcut == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .frame(minWidth: 96)
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(Color.primary.opacity(isRecording ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            if isRecording { RoundedRectangle(cornerRadius: 6).strokeBorder(.tint, lineWidth: 1.5) }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .browserKeyboardFocus(cornerRadius: 6)
                .accessibilityLabel("\(command.title) shortcut")
                .accessibilityValue(isRecording ? "Recording" : shortcut?.display ?? "None")
                .accessibilityHint("Press to record a new shortcut")
                .accessibilityIdentifier("shortcuts.\(command.rawValue)")
            }
            if let problem, problem.command == command {
                Text(problem.message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    /// A shortcut was typed (nil: Delete, to remove it).
    private func finish(_ shortcut: BrowserShortcut?) {
        guard let command = recording else { return }
        recording = nil
        guard let shortcut else {
            preferences.shortcuts.remove(command)
            return
        }
        switch preferences.shortcuts.problem(assigning: shortcut, to: command) {
        case nil: preferences.shortcuts.assign(shortcut, to: command)
        case .takenBy(let owner): conflict = Conflict(shortcut: shortcut, command: command, owner: owner)
        case let other?: problem = (command, other.message)
        }
    }
}

/// Catches the next key press while a shortcut is being recorded, before the
/// menus can act on it. Escape stops recording; Delete or Backspace alone
/// removes the shortcut.
private struct ShortcutRecorder: NSViewRepresentable {
    @Binding var recording: BrowserCommand?
    let onRecord: (BrowserShortcut?) -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.isRecording = recording != nil
        view.onRecord = onRecord
        view.onCancel = { recording = nil }
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    final class MonitorView: NSView {
        var onRecord: ((BrowserShortcut?) -> Void)?
        var onCancel: (() -> Void)?
        private var monitor: Any?
        var isRecording = false {
            didSet {
                guard isRecording != oldValue else { return }
                isRecording ? start() : stop()
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }

        private func start() {
            stop()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isRecording, event.window === self.window else { return event }
                let bare = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
                if event.keyCode == 53, bare {
                    self.onCancel?()
                } else if [51, 117].contains(event.keyCode), bare {
                    self.onRecord?(nil)
                } else if let shortcut = BrowserShortcut(event: event) {
                    self.onRecord?(shortcut)
                }
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
