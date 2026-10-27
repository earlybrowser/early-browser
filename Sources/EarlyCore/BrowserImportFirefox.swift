// SPDX-License-Identifier: MPL-2.0

import Foundation

extension BrowserImportFiles {
    static func configureFirefoxProfile(_ document: inout BrowserImportDocument, at directory: URL) throws {
        let file = directory.appendingPathComponent("containers.json")
        if FileManager.default.fileExists(atPath: file.path) {
            guard let json = try JSONSerialization.jsonObject(with: bounded(file)) as? [String: Any],
                  let identities = json["identities"] as? [[String: Any]], identities.count <= 512 else { throw BrowserImportProblem.invalid }
            var seen = Set<Int>()
            for identity in identities where identity["public"] as? Bool != false {
                guard let number = identity["userContextId"] as? Int, number > 0, seen.insert(number).inserted else { throw BrowserImportProblem.invalid }
                let id = "container.\(number)"
                let name = (identity["name"] as? String).flatMap(BrowserSpace.normalizedName) ?? "Container \(number)"
                let title = String((document.source + " · " + name).prefix(64))
                if let index = document.nodes.firstIndex(where: { $0.id == id }) { document.nodes[index].title = title }
                else { document.nodes.append(.init(id: id, kind: .profile, title: title)) }
            }
        }
        // Read just this boolean preference; no settings, extension secrets,
        // cookie files, saved passwords or credential keys enter the model.
        var separateEssentials: Bool?
        let prefs = directory.appendingPathComponent("prefs.js")
        if document.nodes.contains(where: { $0.kind == .favorite }), FileManager.default.fileExists(atPath: prefs.path) {
            let text = String(decoding: try bounded(prefs), as: UTF8.self)
            let expression = try NSRegularExpression(pattern: #"(?m)^\s*user_pref\("zen\.workspaces\.separate-essentials",\s*(true|false)\);\s*$"#)
            if let match = expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
               let range = Range(match.range(at: 1), in: text) { separateEssentials = text[range] == "true" }
        }
        let profiles = document.nodes.filter { $0.kind == .profile }.map(\.id)
        for index in document.collections.indices { document.collections[index].profileIDs = profiles }
        document.addFirefoxCollections(sharedEssentials: separateEssentials)
        try document.validate()
    }
}
