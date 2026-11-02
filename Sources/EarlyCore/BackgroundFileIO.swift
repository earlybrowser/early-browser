// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation

/// File work owned by an explicit save/import operation. The detached task
/// holds selected-file access until cleanup, and receives caller cancellation.
public enum BackgroundFileIO {
    public static func run<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try operation()
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    public static func write(_ data: Data, to destination: URL) async throws {
        try await run { try writeSynchronously(data, to: destination) }
    }

    public static func copy(_ source: URL, to destination: URL) async throws {
        try await run { try copySynchronously(source, to: destination) }
    }

    public static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        try withAccess([url]) {
            try Task.checkCancellation()
            guard maximumBytes >= 0, maximumBytes < Int.max else { throw CocoaError(.fileReadTooLarge) }
            let descriptor = url.withUnsafeFileSystemRepresentation {
                $0.map { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC) } ?? -1
            }
            guard descriptor >= 0 else { throw fileError() }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? file.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw fileError() }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0,
                  info.st_size <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
            var data = Data()
            while true {
                try Task.checkCancellation()
                let bytes = try file.read(upToCount: min(256 * 1024, maximumBytes - data.count + 1)) ?? Data()
                if bytes.isEmpty { break }
                guard bytes.count <= maximumBytes - data.count else { throw CocoaError(.fileReadTooLarge) }
                data.append(bytes)
            }
            try Task.checkCancellation()
            return data
        }
    }

    /// The final rename is the commit point. Cancellation before it leaves an
    /// existing destination untouched; cancellation after it reports success.
    public static func writeSynchronously(_ data: Data, to destination: URL) throws {
        try atomicDestination(destination) { file in
            var offset = 0
            while offset < data.count {
                try Task.checkCancellation()
                let end = min(data.count, offset + 256 * 1024)
                try file.write(contentsOf: data[offset..<end])
                offset = end
            }
        }
    }

    public static func copySynchronously(_ source: URL, to destination: URL) throws {
        try withAccess([source]) {
            try Task.checkCancellation()
            if sameFile(source, destination) { return }
            let descriptor = source.withUnsafeFileSystemRepresentation {
                $0.map { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC) } ?? -1
            }
            guard descriptor >= 0 else { throw fileError() }
            let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? input.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw fileError() }
            guard info.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileReadUnknown) }
            try atomicDestination(destination) { output in
                while true {
                    try Task.checkCancellation()
                    let bytes = try input.read(upToCount: 256 * 1024) ?? Data()
                    if bytes.isEmpty { return }
                    try output.write(contentsOf: bytes)
                }
            }
        }
    }

    /// A replacement directory stays on the destination volume so the final
    /// rename is atomic, including for a sandbox-granted external destination.
    static func atomicDestination(_ destination: URL, write: (FileHandle) throws -> Void) throws {
        try withAccess([destination]) {
            try Task.checkCancellation()
            guard destination.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
            let files = FileManager.default
            let temporary = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                          appropriateFor: destination, create: true)
            defer { try? files.removeItem(at: temporary) }
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporary.path)
            let staged = temporary.appendingPathComponent("Saved File")
            guard files.createFile(atPath: staged.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            let output = try FileHandle(forWritingTo: staged)
            defer { try? output.close() }
            try write(output)
            try output.synchronize()
            try Task.checkCancellation()
            if let mode = try? files.attributesOfItem(atPath: destination.path)[.posixPermissions] {
                try files.setAttributes([.posixPermissions: mode], ofItemAtPath: staged.path)
            }
            guard Darwin.rename(staged.path, destination.path) == 0 else { throw fileError() }
        }
    }

    public static func withAccess<Value>(_ urls: [URL], _ operation: () throws -> Value) rethrows -> Value {
        let granted = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { granted.forEach { $0.stopAccessingSecurityScopedResource() } }
        return try operation()
    }

    private static func sameFile(_ first: URL, _ second: URL) -> Bool {
        if first.standardizedFileURL.resolvingSymlinksInPath() == second.standardizedFileURL.resolvingSymlinksInPath() { return true }
        guard let a = try? first.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let b = try? second.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else { return false }
        return a.isEqual(b)
    }
    private static func fileError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
