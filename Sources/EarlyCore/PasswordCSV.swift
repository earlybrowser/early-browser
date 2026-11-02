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

    public enum Failure: Error, Equatable, LocalizedError {
        /// No address and password columns: not a password export.
        case unrecognized
        case capacity
        case malformed

        public var errorDescription: String? {
            switch self {
            case .unrecognized: "Choose a CSV file exported from a browser or password manager."
            case .capacity: "This password export is too large. Import a smaller file with at most 100,000 rows, 64 MB in total, and 1 MB per field."
            case .malformed: "This CSV file has an unfinished quoted field. Export it again from your browser or password manager."
            }
        }
    }

    /// Generous bounds for the supported browser and password-manager exports,
    /// including long notes and extra columns. Exceeding a bound rejects the
    /// whole import rather than quietly losing rows or truncating a password.
    public struct Limits: Sendable {
        public var maximumBytes = 64 * 1024 * 1024
        public var maximumRows = 100_000
        public var maximumFieldBytes = 1024 * 1024
        public var maximumColumns = 128
        public init() {}
        public static let standard = Limits()
    }

    static let addressColumns = ["url", "login_uri", "website", "web site", "login url", "uri", "address"]
    static let usernameColumns = ["username", "login_username", "user name", "user", "login", "email", "e-mail"]
    static let passwordColumns = ["password", "login_password"]
    static let noteColumns = ["note", "notes", "extra", "comments"]

    public static func parse(_ text: String, limits: Limits = .standard) throws -> Parsed {
        var header: [String]?
        var address: Int?, password: Int?, username: Int?, note: Int?, realm: Int?, type: Int?
        func column(_ names: [String], in header: [String]) -> Int? {
            for name in names { if let index = header.firstIndex(of: name) { return index } }
            return nil
        }
        var parsed = Parsed(rows: [], skipped: 0)
        try scan(text, limits: limits) { record in
            if header == nil {
                let columns = record.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                header = columns
                address = column(addressColumns, in: columns); password = column(passwordColumns, in: columns)
                guard address != nil, password != nil else { throw Failure.unrecognized }
                username = column(usernameColumns, in: columns); note = column(noteColumns, in: columns)
                realm = column(["httprealm"], in: columns); type = column(["type"], in: columns)
                return
            }
            func value(_ index: Int?) -> String {
                guard let index, index < record.count else { return "" }
                return record[index]
            }
            // Bitwarden also exports notes, cards and identities.
            if type != nil, !["", "login"].contains(value(type).lowercased()) { parsed.skipped += 1; return }
            guard let origin = origin(from: value(address)), !value(password).isEmpty else {
                parsed.skipped += 1
                return
            }
            let httpRealm = value(realm)
            parsed.rows.append(Row(origin: origin, username: value(username), password: value(password),
                                   note: value(note), realm: httpRealm.isEmpty ? nil : httpRealm))
        }
        guard header != nil else { throw Failure.unrecognized }
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
    static func records(_ text: String) throws -> [[String]] {
        var records: [[String]] = []
        try scan(text, limits: .standard) { records.append($0) }
        return records
    }

    /// Scan UTF-8 delimiters without retaining a second copy of every row.
    /// Quoted Unicode, CRLF, commas and escaped quotes preserve their contents.
    private static func scan(_ text: String, limits: Limits, recordFound: ([String]) throws -> Void) throws {
        try Task.checkCancellation()
        guard limits.maximumBytes >= 0, limits.maximumRows > 0,
              limits.maximumFieldBytes > 0, limits.maximumColumns > 0,
              text.utf8.count <= limits.maximumBytes else { throw Failure.capacity }
        var record: [String] = []
        var field: [UInt8] = []
        var quoted = false
        var bytes = text.utf8.makeIterator(), pending: UInt8?
        var processed = 0, rowCount = 0
        if text.hasPrefix("\u{FEFF}") { for _ in 0..<3 { _ = bytes.next() } }
        func endField() throws {
            guard record.count < limits.maximumColumns else { throw Failure.capacity }
            record.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
        }
        func endRecord() throws {
            try Task.checkCancellation()
            try endField()
            if !(record.count == 1 && record[0].isEmpty) {
                // The first record is the header, not an imported row.
                guard rowCount <= limits.maximumRows else { throw Failure.capacity }
                rowCount += 1
                try recordFound(record)
            }
            record.removeAll(keepingCapacity: true)
        }
        func append(_ byte: UInt8) throws {
            guard field.count < limits.maximumFieldBytes else { throw Failure.capacity }
            field.append(byte)
        }
        while let byte = pending ?? bytes.next() {
            pending = nil
            processed += 1
            if processed % 4096 == 0 { try Task.checkCancellation() }
            if quoted {
                if byte == 34 {
                    let next = bytes.next()
                    if next == 34 { try append(34) } else { quoted = false; pending = next }
                } else {
                    try append(byte)
                }
                continue
            }
            switch byte {
            case 34 where field.isEmpty: quoted = true
            case 44: try endField()
            case 10: try endRecord()
            case 13:
                try endRecord()
                let next = bytes.next()
                if next != 10 { pending = next }
            default: try append(byte)
            }
        }
        guard !quoted else { throw Failure.malformed }
        if !field.isEmpty || !record.isEmpty { try endRecord() }
        try Task.checkCancellation()
    }
}
