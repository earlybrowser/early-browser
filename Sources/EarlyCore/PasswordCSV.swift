// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Password files exported by Chrome, Safari and Apple Passwords, Firefox,
/// Edge, 1Password, Bitwarden and LastPass, read by their column names.
/// Early exports Chrome's format, which all of them can import.
public enum PasswordCSV {
    public struct Row: Equatable, Sendable {
        public var origin: String
        public var username: String
        public var password: String
        public var note: String
        public var realm: String?

        public init(origin: String, username: String, password: String, note: String = "", realm: String? = nil) {
            self.origin = origin
            self.username = username
            self.password = password
            self.note = note
            self.realm = realm
        }
    }

    public struct Parsed: Equatable, Sendable {
        public var rows: [Row]
        /// Rows without a website address or password, and other apps' items.
        public var skipped: Int
    }

    public enum Failure: Error, Equatable {
        /// No address and password columns: not a password export.
        case unrecognized
    }

    static let addressColumns = ["url", "login_uri", "website", "web site", "login url", "uri", "address"]
    static let usernameColumns = ["username", "login_username", "user name", "user", "login", "email", "e-mail"]
    static let passwordColumns = ["password", "login_password"]
    static let noteColumns = ["note", "notes", "extra", "comments"]

    public static func parse(_ text: String) throws -> Parsed {
        var records = records(text)
        guard !records.isEmpty else { throw Failure.unrecognized }
        let header = records.removeFirst().map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func column(_ names: [String]) -> Int? {
            for name in names { if let index = header.firstIndex(of: name) { return index } }
            return nil
        }
        guard let address = column(addressColumns), let password = column(passwordColumns) else { throw Failure.unrecognized }
        let username = column(usernameColumns), note = column(noteColumns)
        let realm = column(["httprealm"]), type = column(["type"])
        var parsed = Parsed(rows: [], skipped: 0)
        for record in records {
            func value(_ index: Int?) -> String {
                guard let index, index < record.count else { return "" }
                return record[index]
            }
            // Bitwarden also exports notes, cards and identities.
            if type != nil, !["", "login"].contains(value(type).lowercased()) { parsed.skipped += 1; continue }
            guard let origin = origin(from: value(address)), !value(password).isEmpty else {
                parsed.skipped += 1
                continue
            }
            let httpRealm = value(realm)
            parsed.rows.append(Row(origin: origin, username: value(username), password: value(password),
                                   note: value(note), realm: httpRealm.isEmpty ? nil : httpRealm))
        }
        return parsed
    }

    /// A web address, or a bare host taken as https. Apps' entries (android:)
    /// and LastPass's secure notes (`http://sn`) have no website.
    static func origin(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "http://sn" else { return nil }
        let address = trimmed.contains("://") ? trimmed : "https://" + trimmed
        return URL(string: address).flatMap(SitePermissions.origin(of:))
    }

    /// Chrome's columns: name, url, username, password, note.
    public static func export(_ logins: [SavedLogin]) -> String {
        let sorted = logins.sorted {
            ($0.host, $0.username) < ($1.host, $1.username)
        }
        var lines = ["name,url,username,password,note"]
        for login in sorted {
            lines.append([login.host, login.origin + "/", login.username, login.password, login.note].map(field).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func field(_ value: String) -> String {
        let needsQuotes = value.contains { $0 == "," || $0 == "\"" || $0.isNewline }
            || value.first?.isWhitespace == true || value.last?.isWhitespace == true
        return needsQuotes ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
    }

    /// RFC 4180 records: quoted fields may hold commas, quotes and line breaks.
    static func records(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var quoted = false
        var characters = (text.first == "\u{FEFF}" ? String(text.dropFirst()) : text).makeIterator()
        var pending: Character?
        func endRecord() {
            record.append(field)
            field = ""
            if !(record.count == 1 && record[0].isEmpty) { records.append(record) }
            record = []
        }
        while let character = pending ?? characters.next() {
            pending = nil
            if quoted {
                if character == "\"" {
                    let next = characters.next()
                    if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where field.isEmpty: quoted = true
            case ",":
                record.append(field)
                field = ""
            // "\r\n" is one Character in Swift.
            case "\n", "\r", "\r\n": endRecord()
            default: field.append(character)
            }
        }
        if !field.isEmpty || !record.isEmpty { endRecord() }
        return records
    }
}
