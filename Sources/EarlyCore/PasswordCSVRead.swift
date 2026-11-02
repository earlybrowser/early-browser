// SPDX-License-Identifier: MPL-2.0

import Darwin
import Foundation

extension PasswordCSV {
    /// Call on a worker task. Security-scoped access lasts through reading and
    /// parsing, and no temporary plaintext copy is made.
    public static func read(_ url: URL, limits: Limits = .standard) throws -> Parsed {
        try Task.checkCancellation()
        guard url.isFileURL, limits.maximumBytes >= 0, limits.maximumBytes < Int.max else { throw Failure.capacity }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let descriptor = url.withUnsafeFileSystemRepresentation {
            $0.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw POSIXError(.EIO) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0,
              info.st_size <= limits.maximumBytes else { throw Failure.capacity }
        var data = Data()
        while true {
            try Task.checkCancellation()
            let next = try handle.read(upToCount: min(64 * 1024, limits.maximumBytes - data.count + 1)) ?? Data()
            guard !next.isEmpty else { break }
            guard next.count <= limits.maximumBytes - data.count else { throw Failure.capacity }
            data.append(next)
        }
        try Task.checkCancellation()
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16)
        } else {
            text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        }
        guard let text else { throw Failure.unrecognized }
        return try parse(text, limits: limits)
    }
}
