// SPDX-License-Identifier: MPL-2.0

import Foundation

enum NavigationResponseDisposition: String, Equatable {
    case allow, download, unsupportedSubframe

    static func classify(_ response: URLResponse, canShowMIMEType: Bool, isMainFrame: Bool) -> Self {
        let http = response as? HTTPURLResponse
        // No-content responses leave the existing document intact. They are
        // not downloadable files merely because they have no renderable MIME.
        if http?.statusCode == 204 || http?.statusCode == 205 { return .allow }
        let disposition = http?.value(forHTTPHeaderField: "Content-Disposition")?
            .split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let attachment = disposition == "attachment"
        if canShowMIMEType && !attachment { return .allow }
        // Like other browsers, a top-level attachment or a document Early cannot
        // display is saved. Embedded frames never start a download by themselves.
        return isMainFrame ? .download : .unsupportedSubframe
    }
}

/// Bounded, memory-only evidence. Never store credentials, paths, query strings,
/// fragments, headers, response bodies, or a website-supplied error description.
public struct NavigationDiagnostic: Equatable, Sendable {
    public let tabID: UUID
    public let event: String
    public let origin: String
    public let status: Int?
    public let mimeType: String?
    public let isMainFrame: Bool
    public let errorDomain: String?
    public let errorCode: Int?

    init(tabID: UUID, event: String, url: URL?, status: Int? = nil, mimeType: String? = nil,
         isMainFrame: Bool, error: NSError? = nil) {
        self.tabID = tabID
        self.event = String(event.prefix(64))
        if let url, let scheme = url.scheme, let host = url.host {
            var parts = URLComponents()
            parts.scheme = scheme
            parts.host = host
            parts.port = url.port
            origin = String((parts.string ?? "redacted").prefix(256))
        } else { origin = "redacted" }
        self.status = status
        self.mimeType = mimeType.map { String($0.prefix(128)) }
        self.isMainFrame = isMainFrame
        errorDomain = error.map { String($0.domain.prefix(128)) }
        errorCode = error?.code
    }
}

struct NavigationPolicyCancellation {
    let generation: UUID
    let url: URL?
    let isMainFrame: Bool
}
