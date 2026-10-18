// SPDX-License-Identifier: MPL-2.0

import Foundation

public struct BrowserFolder: Identifiable, Codable, Equatable, Sendable {
    /// Root = 0, child = 1, grandchild = 2. Sibling count is unrestricted.
    public static let maximumNestingDepth = 2

    public let id: UUID
    public let spaceID: UUID
    public var parentID: UUID?
    public var name: String
    public var isExpanded: Bool
    public var sidebarPosition: Int?

    public init(id: UUID = UUID(), spaceID: UUID, parentID: UUID? = nil, name: String, isExpanded: Bool = false) {
        self.id = id
        self.spaceID = spaceID
        self.parentID = parentID
        self.name = name
        self.isExpanded = isExpanded
    }

    public static func validate(_ folders: [BrowserFolder]) throws {
        guard Set(folders.map(\.id)).count == folders.count else { throw SessionError.invalidData }
        let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        for folder in folders {
            guard !folder.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  folder.name.count <= 128 else { throw SessionError.invalidData }
            var seen: Set<UUID> = [folder.id]
            var parent = folder.parentID
            while let id = parent {
                guard seen.insert(id).inserted, seen.count <= 32,
                      let ancestor = byID[id], ancestor.spaceID == folder.spaceID else { throw SessionError.invalidData }
                parent = ancestor.parentID
            }
        }
    }

    /// Structural validation retains the old storage ceiling so previously
    /// saved deep hierarchies stay readable. New creation/moves use the UI limit.
    public static func nestingDepth(of id: UUID, in folders: [BrowserFolder]) -> Int? {
        let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard let folder = byID[id] else { return nil }
        var parent = folder.parentID, seen: Set<UUID> = [id], depth = 0
        while let next = parent {
            guard seen.insert(next).inserted, seen.count <= 32,
                  let ancestor = byID[next], ancestor.spaceID == folder.spaceID else { return nil }
            depth += 1
            parent = ancestor.parentID
        }
        return depth
    }
}
