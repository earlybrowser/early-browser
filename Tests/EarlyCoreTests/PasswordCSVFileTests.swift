// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation
import Testing
@testable import EarlyCore

@Suite
struct PasswordCSVFileTests {
    private let logins = [
        SavedLogin(origin: "https://example.com", username: "ada@example.com", password: "say \"hello\", 🌅\nnext line", note: "Work, personal"),
        SavedLogin(origin: "http://localhost:8080", username: "grace", password: " local password ", note: "日本語")
    ]

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EarlyPasswordExport-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    private func path(of handle: FileHandle) throws -> URL {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        try #require(fcntl(handle.fileDescriptor, F_GETPATH, &path) == 0)
        return path.withUnsafeBufferPointer { URL(fileURLWithFileSystemRepresentation: $0.baseAddress!, isDirectory: false, relativeTo: nil) }
    }

    private func checkPrivate(_ descriptor: Int32) throws {
        var info = stat()
        try #require(fstat(descriptor, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            let code = errno
            #expect(code == ENOENT, "An absent ACL is reported as ENOENT; got \(code)")
            return
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        #expect(acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) != 0, "No ACL may grant access beyond the owner")
    }

    @Test(arguments: [nil, 0o644, 0o666, 0o600] as [Int?])
    func exportsArePrivateForBothNewAndReplacedFiles(previousMode: Int?) throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Early Passwords 日本語.csv")
        if let previousMode {
            try Data("Previous export".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: previousMode], ofItemAtPath: file.path)
        }
        let csv = PasswordCSV.export(logins)
        try PasswordCSV.write(csv, to: file)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        let contents = try String(contentsOf: file, encoding: .utf8)
        #expect(contents == csv)
        let parsed = try PasswordCSV.parse(contents)
        #expect(parsed.rows == logins.map { PasswordCSV.Row(origin: $0.origin, username: $0.username, password: $0.password, note: $0.note) })
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [file.lastPathComponent])
    }

    @Test func theTemporaryFileIsPrivateBeforeAnyPasswordsAreWritten() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Passwords.csv"), old = Data("Previous export".utf8)
        try old.write(to: file)
        var temporary: URL?
        let csv = PasswordCSV.export(logins)
        try PasswordCSV.write(csv, to: file) { handle, contents in
            temporary = try path(of: handle)
            try checkPrivate(handle.fileDescriptor)
            #expect(try handle.offset() == 0)
            #expect(try FileManager.default.attributesOfItem(atPath: temporary!.deletingLastPathComponent().path)[.posixPermissions] as? Int == 0o700)
            #expect(try Data(contentsOf: file) == old, "The destination is untouched while writing")
            try handle.write(contentsOf: contents.prefix(contents.count / 2))
            try checkPrivate(handle.fileDescriptor)
            #expect(try Data(contentsOf: file) == old, "A partial export never replaces the destination")
            try handle.write(contentsOf: contents.suffix(from: contents.count / 2))
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == csv)
        let staged = try #require(temporary)
        #expect(!FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
    }

    private enum WriteFailure: Error { case fullDisk }

    @Test(arguments: [false, true])
    func failedPartialWritesKeepTheDestinationAndRemoveTemporaryPlaintext(replacing: Bool) throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Passwords.csv"), old = Data("Keep this previous export".utf8)
        if replacing {
            try old.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        }
        var temporary: URL?
        #expect(throws: WriteFailure.fullDisk) {
            try PasswordCSV.write(PasswordCSV.export(logins), to: file) { handle, contents in
                temporary = try path(of: handle)
                try handle.write(contentsOf: contents.prefix(contents.count / 2))
                throw WriteFailure.fullDisk
            }
        }
        if replacing {
            #expect(try Data(contentsOf: file) == old)
            #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o644)
        } else { #expect(!FileManager.default.fileExists(atPath: file.path)) }
        let staged = try #require(temporary)
        #expect(!FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
    }

    @Test func failedReplacementKeepsTheOldFileAndRemovesTheCompletedTemporaryFile() throws {
        let directory = try directory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let file = directory.appendingPathComponent("Passwords.csv"), old = Data("Keep this file".utf8)
        try old.write(to: file)
        var temporary: URL?
        #expect(throws: POSIXError.self) {
            try PasswordCSV.write(PasswordCSV.export(logins), to: file) { handle, contents in
                temporary = try path(of: handle)
                try handle.write(contentsOf: contents)
                // Saving was allowed, but the destination stopped being writable
                // before the final atomic replacement.
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            }
        }
        #expect(try Data(contentsOf: file) == old)
        let staged = try #require(temporary)
        #expect(!FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
    }

    @Test func partialContentsAreDiscardedEvenWhenTheTemporaryDirectoryCannotBeCleanedUp() throws {
        let directory = try directory()
        var temporary: URL?
        defer {
            if let folder = temporary?.deletingLastPathComponent() {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
                try? FileManager.default.removeItem(at: folder)
            }
            try? FileManager.default.removeItem(at: directory)
        }
        let file = directory.appendingPathComponent("Passwords.csv"), old = Data("Keep this file".utf8)
        try old.write(to: file)
        #expect(throws: WriteFailure.fullDisk) {
            try PasswordCSV.write(PasswordCSV.export(logins), to: file) { handle, contents in
                let staged = try path(of: handle)
                temporary = staged
                try handle.write(contentsOf: contents.prefix(contents.count / 2))
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: staged.deletingLastPathComponent().path)
                throw WriteFailure.fullDisk
            }
        }
        #expect(try Data(contentsOf: file) == old)
        let staged = try #require(temporary)
        #expect(try Data(contentsOf: staged).isEmpty, "No plaintext is left even if unlinking was refused")
    }

    @Test func replacingAnExportDoesNotKeepItsOldAccessGrants() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Passwords.csv")
        try Data("An older export with shared access".utf8).write(to: file)
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone allow read", file.path]
        try chmod.run()
        chmod.waitUntilExit()
        try #require(chmod.terminationStatus == 0)
        let priorACL = try #require(acl_get_file(file.path, ACL_TYPE_EXTENDED))
        defer { acl_free(UnsafeMutableRawPointer(priorACL)) }
        var entry: acl_entry_t?
        try #require(acl_get_entry(priorACL, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == 0, "The test starts with an access grant")

        try PasswordCSV.write(PasswordCSV.export(logins), to: file)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try checkPrivate(handle.fileDescriptor)
    }
}
