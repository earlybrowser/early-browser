// SPDX-License-Identifier: MPL-2.0

import Foundation

enum NavigationResponseDisposition: String, Equatable {
    case allow, download, unsupported, unsupportedSubframe

    var notice: String? {
        switch self {
        case .allow, .unsupportedSubframe: nil
        case .download: "This file needs download support, which is not available yet."
        case .unsupported: "This response cannot be displayed by Early."
        }
    }

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
        guard isMainFrame else { return .unsupportedSubframe }
        let binaryTypes: Set<String> = ["application/octet-stream", "application/zip", "application/x-zip-compressed",
            "application/gzip", "application/x-gzip", "application/x-apple-diskimage"]
        return attachment || binaryTypes.contains(response.mimeType?.lowercased() ?? "") ? .download : .unsupported
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
