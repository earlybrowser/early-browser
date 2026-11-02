// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation

extension PasswordCSV {
    /// Writes a password export to the destination confirmed by the save panel.
    public static func write(_ csv: String, to destination: URL) throws {
        try write(csv, to: destination) { file, contents in try file.write(contentsOf: contents) }
    }

    /// The writer is injectable so failures after a partial write can be tested.
    static func write(_ csv: String, to destination: URL, writeContents: (FileHandle, Data) throws -> Void) throws {
        guard destination.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        let files = FileManager.default
        // A system replacement directory supports save-panel sandbox grants and
        // stays on the destination's volume. Never fall back to a non-atomic copy.
        let directory = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        defer { try? files.removeItem(at: directory) }
        let directoryFD = try directory.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw CocoaError(.fileWriteInvalidFileName) }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryFD >= 0 else { throw fileError() }
        defer { Darwin.close(directoryFD) }
        // Protect the directory before creating even an empty plaintext file.
        try ownerOnly(directoryFD, mode: 0o700)
        let staged = directory.appendingPathComponent("Passwords.csv")
        let descriptor = Darwin.openat(directoryFD, "Passwords.csv", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw fileError() }
        defer { Darwin.close(descriptor) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do {
            try ownerOnly(descriptor, mode: 0o600)
            try writeContents(file, Data(csv.utf8))
            try file.synchronize()
            // rename replaces the name in one step and keeps the new file's
            // permissions, rather than copying a previous export's metadata.
            try destination.withUnsafeFileSystemRepresentation { path in
                guard let path else { throw CocoaError(.fileWriteInvalidFileName) }
                guard Darwin.renameat(directoryFD, "Passwords.csv", AT_FDCWD, path) == 0 else { throw fileError() }
            }
        } catch {
            let exportError = error
            do { try files.removeItem(at: staged) }
            catch {
                // If a changed directory prevents unlinking, discard the partial
                // contents through the still-open descriptor before closing it.
                do { try file.truncate(atOffset: 0); try file.synchronize() }
                catch { throw ExportCleanupFailure(exportError: exportError, temporaryFile: staged) }
            }
            throw exportError
        }
    }

    private static func ownerOnly(_ descriptor: Int32, mode: mode_t) throws {
        guard Darwin.fchmod(descriptor, mode) == 0 else { throw fileError() }
        // macOS ACLs can grant access beyond POSIX mode bits. Remove inherited
        // grants before writing; replacement must not restore the old file's ACL.
        guard let acl = acl_init(0) else { throw fileError() }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        if acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED) != 0, errno != ENOTSUP { throw fileError() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw fileError() }
        guard info.st_mode & 0o777 == mode else { throw CocoaError(.fileWriteNoPermission) }
    }

    private static func fileError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private struct ExportCleanupFailure: LocalizedError {
        let exportError: any Error
        let temporaryFile: URL
        var errorDescription: String? {
            "\(exportError.localizedDescription) A temporary password file also couldn’t be removed: \(temporaryFile.path)"
        }
    }
}
