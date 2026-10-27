// SPDX-License-Identifier: MPL-2.0

import Foundation
import zlib

/// Reads approved export entries in memory; no archive path is ever extracted.
public enum BrowserImportZIP {
    public static func entries(_ data: Data) throws -> [(name: String, data: Data)] {
        guard data.count <= BrowserImportDocument.maximumBytes else { throw BrowserImportProblem.capacity }
        let bytes = Array(data)
        func number(_ offset: Int, _ count: Int) throws -> Int {
            guard offset >= 0, offset <= bytes.count - count else { throw BrowserImportProblem.invalid }
            return (0..<count).reduce(0) { $0 | Int(bytes[offset + $1]) << ($1 * 8) }
        }
        guard bytes.count >= 22 else { throw BrowserImportProblem.invalid }
        var end: Int?
        for offset in stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1) {
            if try number(offset, 4) == 0x06054b50 { end = offset; break }
        }
        guard let end, try number(end + 4, 2) == 0, try number(end + 6, 2) == 0 else { throw BrowserImportProblem.invalid }
        guard end + 22 + (try number(end + 20, 2)) == bytes.count else { throw BrowserImportProblem.invalid }
        let count = try number(end + 10, 2)
        guard count <= 512, count == (try number(end + 8, 2)) else { throw BrowserImportProblem.capacity }
        var cursor = try number(end + 16, 4), total = 0
        var result: [(String, Data)] = [], names = Set<String>()
        for _ in 0..<count {
            try Task.checkCancellation()
            guard try number(cursor, 4) == 0x02014b50 else { throw BrowserImportProblem.invalid }
            let flags = try number(cursor + 8, 2), method = try number(cursor + 10, 2)
            let crc = try number(cursor + 16, 4), compressed = try number(cursor + 20, 4), size = try number(cursor + 24, 4)
            let nameLength = try number(cursor + 28, 2), extra = try number(cursor + 30, 2), comment = try number(cursor + 32, 2)
            let attributes = try number(cursor + 38, 4), local = try number(cursor + 42, 4)
            let next = cursor + 46 + nameLength + extra + comment
            guard next <= end, let name = String(bytes: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], encoding: .utf8),
                  !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"),
                  !name.split(separator: "/", omittingEmptySubsequences: false).contains(".."),
                  ((attributes >> 16) & 0xf000) != 0xa000, names.insert(name).inserted,
                  flags & 1 == 0, [0, 8].contains(method), size <= BrowserImportDocument.maximumBytes,
                  total <= BrowserImportDocument.maximumBytes - size else { throw BrowserImportProblem.invalid }
            total += size; cursor = next
            // Password CSV entries are never inflated. Localized JSON files are
            // classified by metadata later; only history enters the normalized model.
            guard ["html", "htm", "json"].contains(URL(fileURLWithPath: name).pathExtension.lowercased()) else { continue }
            guard try number(local, 4) == 0x04034b50 else { throw BrowserImportProblem.invalid }
            let localNameLength = try number(local + 26, 2)
            let start = try local + 30 + localNameLength + number(local + 28, 2)
            guard local + 30 + localNameLength <= bytes.count,
                  Array(bytes[(local + 30)..<(local + 30 + localNameLength)]) == Array(name.utf8),
                  try number(local + 8, 2) == method, try number(local + 6, 2) == flags else { throw BrowserImportProblem.invalid }
            guard start <= bytes.count, compressed <= bytes.count - start,
                  size <= max(1, compressed) * 500 else { throw BrowserImportProblem.capacity }
            let payload = Array(bytes[start..<(start + compressed)])
            var decoded: [UInt8]
            if method == 0 {
                guard payload.count == size else { throw BrowserImportProblem.invalid }
                decoded = payload
            } else {
                decoded = [UInt8](repeating: 0, count: max(size, 1))
                var stream = z_stream()
                guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw BrowserImportProblem.invalid }
                defer { inflateEnd(&stream) }
                let status = decoded.withUnsafeMutableBytes { destination in
                    payload.withUnsafeBytes { source in
                        stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                        stream.avail_in = uInt(payload.count)
                        stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                        stream.avail_out = uInt(destination.count)
                        return inflate(&stream, Z_FINISH)
                    }
                }
                guard status == Z_STREAM_END, stream.total_out == size, stream.total_in == compressed else { throw BrowserImportProblem.invalid }
                if size == 0 { decoded = [] }
            }
            let actualCRC = decoded.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
            guard actualCRC == crc else { throw BrowserImportProblem.invalid }
            result.append((name, Data(decoded)))
        }
        return result
    }
}
