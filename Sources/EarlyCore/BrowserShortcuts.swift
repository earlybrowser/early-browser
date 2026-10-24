// SPDX-License-Identifier: MPL-2.0

import Foundation

/// A key with its modifiers, as menus and Settings show it (⌥⌘U).
public struct BrowserShortcut: Codable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1)
        public static let shift = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let control = Modifiers(rawValue: 8)
    }

    /// Keys that aren't a character.
    public static let namedKeys: [String: String] = [
        "leftArrow": "←", "rightArrow": "→", "upArrow": "↑", "downArrow": "↓", "tab": "⇥", "space": "Space",
        "return": "↩", "delete": "⌫", "forwardDelete": "⌦", "home": "↖", "end": "↘", "pageUp": "⇞", "pageDown": "⇟",
    ].merging((1...12).map { ("f\($0)", "F\($0)") }, uniquingKeysWith: { first, _ in first })

    /// A lowercase character, or one of `namedKeys`.
    public let key: String
    public let modifiers: Modifiers

    public init(_ key: String, _ modifiers: Modifiers = .command) {
        self.key = key.count == 1 ? key.lowercased() : key
        self.modifiers = modifiers
    }

    public var isFunctionKey: Bool { key.count > 1 && key.hasPrefix("f") && Int(key.dropFirst()) != nil }

    public var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + (Self.namedKeys[key] ?? key.uppercased())
    }
}

/// Early's commands whose shortcut can be changed in Settings › Shortcuts.
/// Numbered tab and Space shortcuts and Control-Tab stay as they are.
public enum BrowserCommand: String, CaseIterable, Codable, Sendable {
    case newWindow, newPrivateWindow, newTab, openLocation, openFile, closeTab, closeWindow, savePage, exportPDF, printPage
    case find, findNext, findPrevious, useSelectionForFind
    case actualSize, zoomIn, zoomOut, toggleSidebar, toggleReader, translatePage, viewPageSource, webInspector, showDownloads
    case back, forward, showHistory, reopenClosedTab, reopenClosedWindow, clearHistory
    case reload, stopLoading, copyURL, duplicateTab, openTabInNewWindow, renameTab, muteTab, pinTab, toggleFavorite
    case resetPinnedTab, closeOtherTabs, closeTabsBelow, clearTodayTabs
    case swapSplit, focusLeftPane, focusRightPane, removeSplitPane, exitSplit
    case newSpace, previousSpace, nextSpace

    public enum Group: String, CaseIterable, Sendable {
        case windowsAndTabs, find, view, history, tab, splitView, spaces

        public var title: String {
            switch self {
            case .windowsAndTabs: "Windows and Tabs"
            case .find: "Find"
            case .view: "View"
            case .history: "History"
            case .tab: "Tab"
            case .splitView: "Split View"
            case .spaces: "Spaces"
            }
        }

        public var commands: [BrowserCommand] { BrowserCommand.allCases.filter { $0.group == self } }
    }

    public var group: Group {
        switch self {
        case .newWindow, .newPrivateWindow, .newTab, .openLocation, .openFile, .closeTab, .closeWindow, .savePage,
             .exportPDF, .printPage: .windowsAndTabs
        case .find, .findNext, .findPrevious, .useSelectionForFind: .find
        case .actualSize, .zoomIn, .zoomOut, .toggleSidebar, .toggleReader, .translatePage, .viewPageSource,
             .webInspector, .showDownloads: .view
        case .back, .forward, .showHistory, .reopenClosedTab, .reopenClosedWindow, .clearHistory: .history
        case .reload, .stopLoading, .copyURL, .duplicateTab, .openTabInNewWindow, .renameTab, .muteTab, .pinTab,
             .toggleFavorite, .resetPinnedTab, .closeOtherTabs, .closeTabsBelow, .clearTodayTabs: .tab
        case .swapSplit, .focusLeftPane, .focusRightPane, .removeSplitPane, .exitSplit: .splitView
        case .newSpace, .previousSpace, .nextSpace: .spaces
        }
    }

    public var title: String {
        switch self {
        case .newWindow: "New Window"
        case .newPrivateWindow: "New Private Window"
        case .newTab: "New Tab"
        case .openLocation: "Open Location"
        case .openFile: "Open File"
        case .closeTab: "Close Tab"
        case .closeWindow: "Close Window"
        case .savePage: "Save Page As"
        case .exportPDF: "Export as PDF"
        case .printPage: "Print"
        case .find: "Find"
        case .findNext: "Find Next"
        case .findPrevious: "Find Previous"
        case .useSelectionForFind: "Use Selection for Find"
        case .actualSize: "Actual Size"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .toggleSidebar: "Toggle Sidebar"
        case .toggleReader: "Show or Hide Reader"
        case .translatePage: "Translate Page"
        case .viewPageSource: "View Page Source"
        case .webInspector: "Show or Hide Web Inspector"
        case .showDownloads: "Show Downloads"
        case .back: "Back"
        case .forward: "Forward"
        case .showHistory: "Show All History"
        case .reopenClosedTab: "Reopen Closed Tab"
        case .reopenClosedWindow: "Reopen Closed Window"
        case .clearHistory: "Clear History"
        case .reload: "Reload Page"
        case .stopLoading: "Stop Loading"
        case .copyURL: "Copy Current URL"
        case .duplicateTab: "Duplicate Tab"
        case .openTabInNewWindow: "Open Tab in New Window"
        case .renameTab: "Rename Tab"
        case .muteTab: "Mute or Unmute Tab"
        case .pinTab: "Pin or Unpin Tab"
        case .toggleFavorite: "Add to or Remove from Favorites"
        case .resetPinnedTab: "Reset to Pinned URL"
        case .closeOtherTabs: "Close Other Tabs"
        case .closeTabsBelow: "Close Tabs Below"
        case .clearTodayTabs: "Clear Today Tabs"
        case .swapSplit: "Swap Sides"
        case .focusLeftPane: "Focus Left Pane"
        case .focusRightPane: "Focus Right Pane"
        case .removeSplitPane: "Remove Current Pane from Split"
        case .exitSplit: "Exit Split View"
        case .newSpace: "New Space"
        case .previousSpace: "Previous Space"
        case .nextSpace: "Next Space"
        }
    }

    /// The shortcut it has unless changed. Most of them follow Safari.
    public var defaultShortcut: BrowserShortcut? {
        let shiftCommand: BrowserShortcut.Modifiers = [.command, .shift]
        let optionCommand: BrowserShortcut.Modifiers = [.command, .option]
        return switch self {
        case .newWindow: BrowserShortcut("n")
        case .newPrivateWindow: BrowserShortcut("n", shiftCommand)
        case .newTab: BrowserShortcut("t")
        case .openLocation: BrowserShortcut("l")
        case .openFile: BrowserShortcut("o")
        case .closeTab: BrowserShortcut("w")
        case .closeWindow: BrowserShortcut("w", shiftCommand)
        case .savePage: BrowserShortcut("s")
        case .printPage: BrowserShortcut("p")
        case .find: BrowserShortcut("f")
        case .findNext: BrowserShortcut("g")
        case .findPrevious: BrowserShortcut("g", shiftCommand)
        case .useSelectionForFind: BrowserShortcut("e")
        case .actualSize: BrowserShortcut("0")
        case .zoomIn: BrowserShortcut("+")
        case .zoomOut: BrowserShortcut("-")
        case .toggleSidebar: BrowserShortcut("s", shiftCommand)
        case .toggleReader: BrowserShortcut("r", shiftCommand)
        case .viewPageSource: BrowserShortcut("u", optionCommand)
        case .webInspector: BrowserShortcut("i", optionCommand)
        case .showDownloads: BrowserShortcut("l", optionCommand)
        case .back: BrowserShortcut("[")
        case .forward: BrowserShortcut("]")
        case .showHistory: BrowserShortcut("y")
        case .reopenClosedTab: BrowserShortcut("t", shiftCommand)
        case .reload: BrowserShortcut("r")
        case .stopLoading: BrowserShortcut(".")
        case .copyURL: BrowserShortcut("c", shiftCommand)
        case .closeOtherTabs: BrowserShortcut("w", optionCommand)
        case .newSpace: BrowserShortcut("n", optionCommand)
        case .previousSpace: BrowserShortcut("leftArrow", optionCommand)
        case .nextSpace: BrowserShortcut("rightArrow", optionCommand)
        case .exportPDF, .translatePage, .reopenClosedWindow, .clearHistory, .duplicateTab, .openTabInNewWindow,
             .renameTab, .muteTab, .pinTab, .toggleFavorite, .resetPinnedTab, .closeTabsBelow, .clearTodayTabs,
             .swapSplit, .focusLeftPane, .focusRightPane, .removeSplitPane, .exitSplit: nil
        }
    }
}

/// The person's shortcuts: each command's default unless changed or removed.
public struct BrowserShortcuts: Codable, Equatable, Sendable {
    private enum Choice: Equatable, Sendable { case shortcut(BrowserShortcut), removed }
    private var changes: [BrowserCommand: Choice] = [:]

    public init() {}

    public enum Problem: Equatable, Sendable {
        /// Needs ⌘ or ⌃ (function keys excepted), so typing never triggers it.
        case needsModifier
        /// macOS's, editing's or one Early keeps for itself.
        case reserved
        case takenBy(BrowserCommand)

        public var message: String {
            switch self {
            case .needsModifier: "Use Command or Control with the key."
            case .reserved: "That shortcut belongs to macOS or another part of Early."
            case .takenBy(let command): "That shortcut is already used by \(command.title)."
            }
        }
    }

    /// macOS's own, standard editing, and those Early keeps: numbered tabs
    /// (⌘1–⌘9), numbered Spaces (⌥⌘1–⌥⌘9) and the tab switcher (⌃Tab).
    public static let reserved: Set<BrowserShortcut> = {
        var keys: Set<BrowserShortcut> = [
            BrowserShortcut("q"), BrowserShortcut("h"), BrowserShortcut("h", [.command, .option]), BrowserShortcut("m"),
            BrowserShortcut(","), BrowserShortcut("`"), BrowserShortcut("`", [.command, .shift]), BrowserShortcut("tab"),
            BrowserShortcut("tab", [.command, .shift]), BrowserShortcut("space"),
            BrowserShortcut("c"), BrowserShortcut("v"), BrowserShortcut("x"), BrowserShortcut("a"), BrowserShortcut("z"),
            BrowserShortcut("z", [.command, .shift]), BrowserShortcut("v", [.command, .shift, .option]),
            BrowserShortcut("f", [.command, .control]), BrowserShortcut("q", [.command, .control]),
            BrowserShortcut("tab", .control), BrowserShortcut("tab", [.control, .shift]),
        ]
        for number in 1...9 {
            keys.insert(BrowserShortcut("\(number)"))
            keys.insert(BrowserShortcut("\(number)", [.command, .option]))
        }
        return keys
    }()

    public func shortcut(for command: BrowserCommand) -> BrowserShortcut? {
        switch changes[command] {
        case .shortcut(let shortcut): shortcut
        case .removed?: nil
        case nil: command.defaultShortcut
        }
    }

    public func isChanged(_ command: BrowserCommand) -> Bool { changes[command] != nil }
    public var hasChanges: Bool { !changes.isEmpty }

    /// The command that has this shortcut now.
    public func command(using shortcut: BrowserShortcut) -> BrowserCommand? {
        BrowserCommand.allCases.first { self.shortcut(for: $0) == shortcut }
    }

    public func problem(assigning shortcut: BrowserShortcut, to command: BrowserCommand) -> Problem? {
        guard shortcut.isFunctionKey || !shortcut.modifiers.isDisjoint(with: [.command, .control]) else { return .needsModifier }
        guard !Self.reserved.contains(shortcut) else { return .reserved }
        if let other = self.command(using: shortcut), other != command { return .takenBy(other) }
        return nil
    }

    /// Gives `command` this shortcut. Taking another command's needs
    /// `replacing`, which leaves that one without a shortcut.
    @discardableResult
    public mutating func assign(_ shortcut: BrowserShortcut, to command: BrowserCommand, replacing: Bool = false) -> Problem? {
        let problem = problem(assigning: shortcut, to: command)
        switch problem {
        case .takenBy(let other) where replacing: remove(other)
        case nil: break
        default: return problem
        }
        set(.shortcut(shortcut), for: command)
        return nil
    }

    /// Leaves it without a shortcut.
    public mutating func remove(_ command: BrowserCommand) { set(.removed, for: command) }

    /// Back to its own shortcut, unless another command has taken it since.
    @discardableResult
    public mutating func reset(_ command: BrowserCommand) -> Problem? {
        if let original = command.defaultShortcut, let other = self.command(using: original), other != command {
            return .takenBy(other)
        }
        changes[command] = nil
        return nil
    }

    public mutating func resetAll() { changes.removeAll() }

    private mutating func set(_ choice: Choice, for command: BrowserCommand) {
        let isDefault = switch choice {
        case .shortcut(let shortcut): shortcut == command.defaultShortcut
        case .removed: command.defaultShortcut == nil
        }
        changes[command] = isDefault ? nil : choice
    }

    // Saved as `{"newTab": {...}, "print": null}`; unknown commands are dropped.
    public init(from decoder: any Decoder) throws {
        let saved = try decoder.singleValueContainer().decode([String: BrowserShortcut?].self)
        for (name, shortcut) in saved {
            guard let command = BrowserCommand(rawValue: name) else { continue }
            set(shortcut.map(Choice.shortcut) ?? .removed, for: command)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var saved: [String: BrowserShortcut?] = [:]
        for (command, choice) in changes {
            switch choice {
            case .shortcut(let shortcut): saved[command.rawValue] = .some(shortcut)
            case .removed: saved[command.rawValue] = .some(nil)
            }
        }
        var container = encoder.singleValueContainer()
        try container.encode(saved)
    }
}
