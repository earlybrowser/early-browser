// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation

/// Worker-only copy of a chosen extension. A private staging path is validated
/// by WebKit before the host publishes its final name and catalog entry.
public enum ExtensionFileTransfer {
    public static func copy(_ source: URL, to destination: URL) throws {
        try BackgroundFileIO.withAccess([source, destination]) {
            try Task.checkCancellation()
            let files = FileManager.default
            let temporary = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                          appropriateFor: destination, create: true)
            defer { try? files.removeItem(at: temporary) }
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporary.path)
            let staged = temporary.appendingPathComponent("Extension")
            try copyItem(source, to: staged)
            try Task.checkCancellation()
            // Publishing is exclusive: never replace or clean up a destination
            // created by another operation, even after our copy began.
            try publish(staged, to: destination)
        }
    }

    public static func publish(_ staged: URL, to destination: URL) throws {
        guard renamex_np(staged.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func copyItem(_ source: URL, to destination: URL) throws {
        try Task.checkCancellation()
        let files = FileManager.default
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
        if values.isSymbolicLink == true {
            // Preserve a link as a link; never traverse into unrelated folders.
            try files.copyItem(at: source, to: destination)
        } else if values.isDirectory == true {
            try files.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for child in try files.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try copyItem(child, to: destination.appendingPathComponent(child.lastPathComponent))
            }
        } else {
            guard values.isRegularFile == true else { throw CocoaError(.fileReadUnknown) }
            try BackgroundFileIO.copySynchronously(source, to: destination)
        }
        let attributes = try files.attributesOfItem(atPath: source.path)
        if values.isSymbolicLink != true {
            try files.setAttributes(attributes.filter { [.posixPermissions, .modificationDate].contains($0.key) }, ofItemAtPath: destination.path)
        }
        try Task.checkCancellation()
    }
}
