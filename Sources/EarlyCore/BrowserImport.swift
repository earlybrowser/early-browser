// SPDX-License-Identifier: MPL-2.0

import Foundation
import CryptoKit

/// Organization only. Readers never retain form state, cookies, or credentials.
public struct BrowserImportDocument: Equatable, Sendable {
    public var source: String
    public var nodes: [BrowserImportNode]
    public var notices: [String]
    public var collections: [BrowserImportCollection]
    public init(source: String, nodes: [BrowserImportNode] = [], notices: [String] = [], collections: [BrowserImportCollection] = []) {
        self.source = source; self.nodes = nodes; self.notices = notices; self.collections = collections
    }
    public static let maximumBytes = 64 * 1024 * 1024
    public static let maximumNodes = 80_000
    public static let maximumVisits = 50_000

    public var initiallySelected: Set<String> {
        let parents = Set(nodes.compactMap(\.parentID))
        return Set(nodes.filter {
            (![.history, .openTab].contains($0.kind) && $0.url != nil)
                || ([.folder, .space].contains($0.kind) && !parents.contains($0.id))
        }.map(\.id))
    }

    /// Selecting descendants retains their necessary ancestors, including empty folders.
    public func included(_ selected: Set<String>) -> Set<String> {
        let parents = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.parentID) })
        var result = selected
        for id in selected {
            var next = parents[id] ?? nil
            var seen = Set<String>()
            while let value = next, seen.insert(value).inserted {
                result.insert(value); next = parents[value] ?? nil
            }
        }
        return result
    }

    public func validate() throws {
        guard nodes.count <= Self.maximumNodes, Set(nodes.map(\.id)).count == nodes.count else { throw BrowserImportProblem.capacity }
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        guard Set(collections.map(\.id)).count == collections.count else { throw BrowserImportProblem.invalid }
        for collection in collections {
            guard byID[collection.id]?.kind == .category, !collection.profileIDs.isEmpty,
                  Set(collection.profileIDs).count == collection.profileIDs.count,
                  collection.profileIDs.allSatisfy({ byID[$0]?.kind == .profile }),
                  collection.defaultProfileIDs.isSubset(of: Set(collection.profileIDs)),
                  collection.allowsCopies || collection.defaultProfileIDs.count <= 1 else { throw BrowserImportProblem.invalid }
            var parent = byID[collection.id]?.parentID
            var seen = Set<String>()
            while let id = parent, seen.insert(id).inserted {
                guard !collections.contains(where: { $0.id == id }) else { throw BrowserImportProblem.invalid }
                parent = byID[id]?.parentID
            }
        }
        for node in nodes {
            guard !node.id.isEmpty, node.id.utf8.count <= 1024, node.title.count <= 512, (node.detail?.count ?? 0) <= 1024 else { throw BrowserImportProblem.invalid }
            guard node.kind != .profile || node.parentID == nil,
                  node.order.map({ (0...Self.maximumNodes).contains($0) }) ?? true else { throw BrowserImportProblem.invalid }
            var parent = node.parentID, seen: Set<String> = [node.id]
            while let id = parent {
                guard seen.count <= 64, seen.insert(id).inserted, let ancestor = byID[id] else { throw BrowserImportProblem.invalid }
                parent = ancestor.parentID
            }
            if let url = node.url, Self.webURL(url.absoluteString) == nil { throw BrowserImportProblem.invalid }
            if node.kind == .history, node.visitedAt?.timeIntervalSince1970.isFinite != true { throw BrowserImportProblem.invalid }
        }
    }

    public static func webURL(_ text: String) -> URL? {
        guard text.utf8.count <= 4096, let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }

    public static func identity(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct BrowserImportNode: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case profile, space, category, folder, bookmark, pin, favorite, openTab, history }
    public var id: String
    public var parentID: String?
    public var kind: Kind
    public var title: String
    public var url: URL?
    public var visitedAt: Date?
    public var color: BrowserSpace.Color?
    public var icon: SpaceIcon?
    public var order: Int?
    public var detail: String?
    public init(id: String, parentID: String? = nil, kind: Kind, title: String, url: URL? = nil,
                visitedAt: Date? = nil, color: BrowserSpace.Color? = nil, icon: SpaceIcon? = nil, order: Int? = nil, detail: String? = nil) {
        self.id = id; self.parentID = parentID; self.kind = kind
        self.title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
        if self.title.isEmpty { self.title = url?.host ?? "Untitled" }
        self.url = url; self.visitedAt = visitedAt; self.color = color; self.icon = icon; self.order = order
        self.detail = detail.map { String($0.prefix(1024)) }
    }
}

public enum BrowserImportProblem: LocalizedError, Equatable, Sendable {
    case invalid, capacity, cancelled, unsupported(String), missingDestination, tooDeep(String)
    case collectionDestination(String)
    public var errorDescription: String? {
        switch self {
        case .invalid: "This file does not contain a supported browser export, or its organization is damaged."
        case .capacity: "This import exceeds Early’s safe size or item limits. Select a smaller export."
        case .cancelled: "Import cancelled."
        case .unsupported(let message): message
        case .missingDestination: "A destination changed or was deleted. Choose your destinations again."
        case .tooDeep(let name): "“\(name)” exceeds eight nested folder levels. Choose Flatten Deep Folders, another destination, or deselect this branch."
        case .collectionDestination(let name): "Choose a destination for “\(name)” before importing."
        }
    }
}
