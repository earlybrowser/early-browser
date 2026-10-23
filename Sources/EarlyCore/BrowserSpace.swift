// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Profile-local organization only; website storage belongs to the profile.
public struct BrowserSpace: Identifiable, Codable, Equatable, Sendable {
    public enum Color: String, Codable, CaseIterable, Sendable {
        case gray, blue, purple, pink, red, orange, yellow, green
    }

    public let id: UUID
    public let profileID: UUID
    public var name: String
    public var color: Color
    public var icon: SpaceIcon?

    public init(id: UUID = UUID(), profileID: UUID, name: String, color: Color = .blue, icon: SpaceIcon? = nil) {
        self.id = id
        self.profileID = profileID
        self.name = name
        self.color = color
        self.icon = icon
    }

    private enum CodingKeys: String, CodingKey { case id, profileID, name, color, icon }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        profileID = try values.decode(UUID.self, forKey: .profileID)
        name = try values.decode(String.self, forKey: .name)
        color = try values.decode(Color.self, forKey: .color)
        // Decorative metadata must not prevent restoring a whole workspace.
        // This also retires emoji saved by the initial local appearance build.
        icon = try? values.decode(SpaceIcon.self, forKey: .icon)
    }

    public static func normalizedName(_ name: String) -> String? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 64,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }

    static func validate(_ spaces: [Self], profileID: UUID) throws {
        guard !spaces.isEmpty, Set(spaces.map(\.id)).count == spaces.count,
              spaces.allSatisfy({ $0.profileID == profileID && normalizedName($0.name) == $0.name }) else {
            throw SessionError.invalidData
        }
    }

    /// Legacy sessions stored opaque Space IDs. Preserve every reference and
    /// give the current Space the old Personal name, including zero-tab Spaces.
    static func migrated(profileID: UUID, activeID: UUID, tabs: [BrowserTab], folders: [BrowserFolder],
                         selection: [UUID: UUID], closed: [ClosedTab]) -> [Self] {
        let references = [activeID] + tabs.map(\.spaceID) + folders.map(\.spaceID)
            + selection.keys.sorted { $0.uuidString < $1.uuidString } + closed.map(\.tab.spaceID)
        var seen = Set<UUID>()
        return references.filter { seen.insert($0).inserted }.enumerated().map { index, id in
            Self(id: id, profileID: profileID, name: index == 0 ? "Personal" : "Space \(index + 1)")
        }
    }
}
