// SPDX-License-Identifier: MPL-2.0

import Foundation
@testable import EarlyWeb
import Testing

/// Response bodies read in the network's own chunks, never past their limit,
/// through a stand-in network: nothing leaves this Mac.
@Suite(.serialized)
struct BoundedResponseTests {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedProtocol.self]
        return URLSession(configuration: configuration)
    }()

    private func request(_ path: String) -> URLRequest { URLRequest(url: URL(string: "https://fixture.invalid\(path)")!) }

    @Test func aBodyWithinTheLimitArrivesWhole() async throws {
        let (data, response) = try await BoundedResponse.load(request("/chunks?count=8&size=1000"), in: Self.session, limit: 8_000)
        #expect(data.count == 8_000 && (response as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test func aLongerBodyStopsAtTheLimitWhetherOrNotItSaysItsLength() async throws {
        for path in ["/chunks?count=8&size=1000&length=yes", "/chunks?count=200&size=1000"] {
            await #expect(throws: URLError.self) {
                _ = try await BoundedResponse.load(request(path), in: Self.session, limit: 7_999)
            }
        }
        #expect(ChunkedProtocol.deliveredAfterLimit.value <= 1, "Cancelled as soon as it passed the limit")
    }

    @Test func aRefusedRedirectReturnsTheRedirectItself() async throws {
        let (_, refused) = try await BoundedResponse.load(request("/redirect"), in: Self.session, limit: 1_000, redirects: { _, _ in false })
        #expect((refused as? HTTPURLResponse)?.statusCode == 302)
        let (data, followed) = try await BoundedResponse.load(request("/redirect"), in: Self.session, limit: 8_000)
        #expect((followed as? HTTPURLResponse)?.statusCode == 200 && data.count == 1_000)
    }
}

/// Sends `count` chunks of `size` bytes, with or without a length, or a redirect.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func reset() { lock.withLock { count = 0 } }
    func increment() { lock.withLock { count += 1 } }
}

private final class ChunkedProtocol: URLProtocol, @unchecked Sendable {
    static let deliveredAfterLimit = Counter()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var stopped = false

    override func startLoading() {
        let url = request.url!
        if url.path == "/redirect" {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": "https://fixture.invalid/chunks?count=1&size=1000"])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "https://fixture.invalid/chunks?count=1&size=1000")!),
                                redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        let count = Int(value("count") ?? "1") ?? 1, size = Int(value("size") ?? "1") ?? 1
        var headers = ["Content-Type": "application/octet-stream"]
        if value("length") != nil { headers["Content-Length"] = "\(count * size)" }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!,
                            cacheStoragePolicy: .notAllowed)
        Self.deliveredAfterLimit.reset()
        var sent = 0
        for _ in 0..<count {
            if stopped { break }
            client?.urlProtocol(self, didLoad: Data(repeating: 7, count: size))
            sent += size
            if sent > 8_000 { Self.deliveredAfterLimit.increment() }
            Thread.sleep(forTimeInterval: 0.001)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { stopped = true }
}
