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
            do {
                _ = try await BoundedResponse.load(request(path), in: Self.session, limit: 7_999)
                Issue.record("An oversized response must fail")
            } catch let error as URLError { #expect(error.code == .dataLengthExceedsMaximum) }
        }
        #expect(ChunkedProtocol.deliveredAfterLimit.value <= 1, "Cancelled as soon as it passed the limit")
    }

    @Test func aRefusedRedirectReturnsTheRedirectItself() async throws {
        let (_, refused) = try await BoundedResponse.load(request("/redirect"), in: Self.session, limit: 1_000, redirects: { _, _ in false })
        #expect((refused as? HTTPURLResponse)?.statusCode == 302)
        let (data, followed) = try await BoundedResponse.load(request("/redirect"), in: Self.session, limit: 8_000)
        #expect((followed as? HTTPURLResponse)?.statusCode == 200 && data.count == 1_000)
    }

    @Test(arguments: [false, true])
    func cancellationBeforeOrDuringWaiterInstallationSettlesExactlyOnce(early: Bool) async throws {
        let reader = BoundedResponse(limit: 1_000)
        let session = Self.session
        let transport = session.dataTask(with: request("/stall"))
        defer { transport.cancel() }
        let started = Counter()
        let cancel: @Sendable () -> Void = {
            reader.urlSession(session, task: transport, didCompleteWithError: URLError(.cancelled))
        }
        if early { cancel() }
        do {
            _ = try await reader.waitForCompletion {
                started.increment()
                // This callback runs during continuation installation, before
                // it returns to the awaiting task. Use a different error in
                // the early case so dropping the terminal result fails cleanly.
                if early { reader.urlSession(session, task: transport, didCompleteWithError: URLError(.timedOut)) }
                else { cancel() }
                reader.urlSession(session, task: transport, didCompleteWithError: URLError(.badServerResponse))
            }
            Issue.record("Cancellation must be returned to the waiter")
        } catch let error as URLError { #expect(error.code == .cancelled) }
        #expect(started.value == (early ? 0 : 1))
    }

    @Test func cancellingAlreadyCancelledAndActiveTasksAlwaysSettles() async throws {
        let session = Self.session, request = request("/stall")
        for _ in 0..<20 {
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await BoundedResponse.load(request, in: session, limit: 1_000)
            }
            do {
                _ = try await task.value
                Issue.record("An already-cancelled task must fail")
            } catch let error as URLError { #expect(error.code == .cancelled) }
        }
        let started = ChunkedProtocol.startedStalls.value, stopped = ChunkedProtocol.stoppedStalls.value
        let active = Task { try await BoundedResponse.load(request, in: session, limit: 1_000) }
        defer { active.cancel() }
        try await waitUntil { ChunkedProtocol.startedStalls.value > started }
        active.cancel()
        do {
            _ = try await active.value
            Issue.record("An active request must report cancellation")
        } catch let error as URLError { #expect(error.code == .cancelled) }
        try await waitUntil { ChunkedProtocol.stoppedStalls.value > stopped }
    }

    @Test func transportErrorsStayIntact() async throws {
        do {
            _ = try await BoundedResponse.load(request("/error"), in: Self.session, limit: 1_000)
            Issue.record("The transport failure must reach the caller")
        } catch let error as URLError { #expect(error.code == .networkConnectionLost) }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            try #require(ContinuousClock.now < deadline, "The synthetic transport did not signal")
            try await Task.sleep(for: .milliseconds(5))
        }
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
    static let startedStalls = Counter()
    static let stoppedStalls = Counter()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private let lock = NSLock()
    private var stopped = false

    override func startLoading() {
        let url = request.url!
        if url.path == "/stall" { Self.startedStalls.increment(); return }
        if url.path == "/error" { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
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
            if lock.withLock({ stopped }) { break }
            client?.urlProtocol(self, didLoad: Data(repeating: 7, count: size))
            sent += size
            if sent > 8_000 { Self.deliveredAfterLimit.increment() }
            Thread.sleep(forTimeInterval: 0.001)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        lock.withLock { stopped = true }
        if request.url?.path == "/stall" { Self.stoppedStalls.increment() }
    }
}
