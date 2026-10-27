// SPDX-License-Identifier: MPL-2.0

import Foundation

extension BrowserImportReaders {
    /// Chromium SNSS v3 only. OSCrypt-encrypted v5 is deliberately not decrypted.
    static func chromiumSession(_ data: Data, name: String) throws -> BrowserImportDocument {
        let bytes = Array(data)
        func integer(_ input: [UInt8], _ offset: Int, bytes count: Int = 4) throws -> Int {
            guard offset >= 0, offset <= input.count - count else { throw BrowserImportProblem.invalid }
            return (0..<count).reduce(0) { $0 | Int(input[offset + $1]) << ($1 * 8) }
        }
        guard bytes.count >= 8, Array(bytes.prefix(4)) == Array("SNSS".utf8) else { throw BrowserImportProblem.invalid }
        let version = try integer(bytes, 4)
        guard version == 3 else {
            throw BrowserImportProblem.unsupported(version == 5
                ? "These Chromium sessions are encrypted. Early does not decrypt credential-protected data. Save the tabs or groups as bookmarks, then export HTML."
                : "This Chromium session version is not supported. Save its tabs as bookmarks and export HTML instead.")
        }
        struct Navigation { var url: String; var title: String }
        struct Tab {
            var window: Int?
            var position = 0
            var selected = 0
            var pinned = false
            var group: String?
            var entries: [Int: Navigation] = [:]
        }
        var tabs: [Int: Tab] = [:], closedWindows = Set<Int>(), windowTypes: [Int: Int] = [:]
        var groupNames: [String: String] = [:]
        var cursor = 8, commands = 0
        func token(_ input: [UInt8], _ offset: Int) throws -> String {
            guard offset <= input.count - 16 else { throw BrowserImportProblem.invalid }
            return input[offset..<(offset + 16)].map { String(format: "%02x", $0) }.joined()
        }
        func string(_ input: [UInt8], cursor: inout Int, wide: Bool) throws -> String {
            let count = try integer(input, cursor); cursor += 4
            guard count <= 65_536 else { throw BrowserImportProblem.capacity }
            let size = count * (wide ? 2 : 1)
            guard cursor <= input.count - size else { throw BrowserImportProblem.invalid }
            let data = Data(input[cursor..<(cursor + size)])
            cursor += (size + 3) & ~3
            guard let text = String(data: data, encoding: wide ? .utf16LittleEndian : .utf8) else { throw BrowserImportProblem.invalid }
            return text
        }
        while cursor < bytes.count {
            try Task.checkCancellation()
            let count = try integer(bytes, cursor, bytes: 2); cursor += 2
            guard count >= 1, count <= bytes.count - cursor, commands < 500_000 else { throw BrowserImportProblem.invalid }
            let command = bytes[cursor], payload = Array(bytes[(cursor + 1)..<(cursor + count)])
            cursor += count; commands += 1
            switch command {
            case 0:
                let window = try integer(payload, 0), id = try integer(payload, 4)
                tabs[id, default: Tab()].window = window
            case 2:
                let id = try integer(payload, 0)
                tabs[id, default: Tab()].position = try integer(payload, 4)
            case 6:
                // Pickle: length header, tab ID, entry index, UTF-8 URL, UTF-16 title.
                guard try integer(payload, 0) <= payload.count - 4 else { throw BrowserImportProblem.invalid }
                let id = try integer(payload, 4), index = try integer(payload, 8)
                var offset = 12
                let url = try string(payload, cursor: &offset, wide: false)
                let title = try string(payload, cursor: &offset, wide: true)
                // Everything after title (encoded page/form state, referrers,
                // user agents and request metadata) is intentionally not read.
                tabs[id, default: Tab()].entries[index] = Navigation(url: url, title: title)
            case 7:
                let id = try integer(payload, 0)
                tabs[id, default: Tab()].selected = try integer(payload, 4)
            case 9:
                windowTypes[try integer(payload, 0)] = try integer(payload, 4)
            case 12:
                let id = try integer(payload, 0)
                tabs[id, default: Tab()].pinned = try integer(payload, 4, bytes: 1) != 0
            case 16: tabs.removeValue(forKey: try integer(payload, 0))
            case 17: closedWindows.insert(try integer(payload, 0))
            case 25:
                let id = try integer(payload, 0)
                tabs[id, default: Tab()].group = try integer(payload, 24, bytes: 1) == 0 ? nil : token(payload, 8)
            case 27:
                var offset = 20
                groupNames[try token(payload, 4)] = try string(payload, cursor: &offset, wide: true)
            case 5:
                let id = try integer(payload, 0), index = try integer(payload, 4)
                let previous = tabs[id]?.entries ?? [:]
                tabs[id]?.entries = previous.filter { $0.key < index }
            case 11:
                let id = try integer(payload, 0), count = try integer(payload, 4)
                let previous = tabs[id]?.entries ?? [:]
                tabs[id]?.entries = Dictionary(uniqueKeysWithValues: previous.filter { $0.key >= count }.map { ($0.key - count, $0.value) })
            case 24:
                let id = try integer(payload, 0), index = try integer(payload, 4), count = try integer(payload, 8)
                let previous = tabs[id]?.entries ?? [:]
                tabs[id]?.entries = Dictionary(uniqueKeysWithValues: previous.filter { $0.key < index || $0.key >= index + count }.map { ($0.key >= index + count ? $0.key - count : $0.key, $0.value) })
            default: break // Unrelated optional metadata never enters the import model.
            }
            guard tabs.count <= 20_000 else { throw BrowserImportProblem.capacity }
        }
        var builder = Builder(name: name), groups: [String: String] = [:]
        for (id, tab) in tabs.sorted(by: { ($0.value.window ?? 0, $0.value.position, $0.key) < ($1.value.window ?? 0, $1.value.position, $1.key) }) {
            guard let window = tab.window, !closedWindows.contains(window), windowTypes[window, default: 0] == 0 else { continue }
            let index = tab.entries[tab.selected] != nil ? tab.selected : tab.entries.keys.min(by: { abs($0 - tab.selected) < abs($1 - tab.selected) })
            guard let index, let entry = tab.entries[index] else { continue }
            var parent = "profile"
            if let group = tab.group {
                if let existing = groups[group] { parent = existing }
                else { parent = try builder.folder(groupNames[group] ?? "Tab group", parent: "profile"); groups[group] = parent }
            }
            try builder.link(entry.url, title: entry.title, parent: parent, kind: tab.group != nil || tab.pinned ? .pin : .openTab)
            _ = id
        }
        builder.document.notices.append("This is an unencrypted Chromium session snapshot. Groups become ordinary folders; only current URLs, titles, order and pin state transfer. Website sessions and form state are discarded.")
        try builder.document.validate(); return builder.document
    }
}
