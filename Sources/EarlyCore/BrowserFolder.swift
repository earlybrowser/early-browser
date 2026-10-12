import Foundation

public struct BrowserFolder: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let spaceID: UUID
    public var parentID: UUID?
    public var name: String
    public var isExpanded: Bool

    public init(id: UUID = UUID(), spaceID: UUID, parentID: UUID? = nil, name: String, isExpanded: Bool = true) {
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
}
