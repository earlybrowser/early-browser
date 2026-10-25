// SPDX-License-Identifier: MPL-2.0

import Foundation

/// A response body read as it arrives, in the network's own chunks, and never
/// more than `limit` bytes of it: a longer one is cancelled as soon as it
/// passes that, so a website can't make Early hold more. Reading it byte by
/// byte did the same at about twelve times the work.
final class BoundedResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Whether to follow a redirect to the new request.
    typealias Redirects = @Sendable (HTTPURLResponse, URLRequest) -> Bool

    private let limit: Int
    private let redirects: Redirects
    /// Guards what the session's queue and the caller share.
    private let lock = NSLock()
    private var body = Data()
    private var response: URLResponse?
    private var continuation: CheckedContinuation<(Data, URLResponse), any Error>?

    private init(limit: Int, redirects: @escaping Redirects) {
        self.limit = limit
        self.redirects = redirects
    }

    static func load(_ request: URLRequest, in session: URLSession, limit: Int,
                     redirects: @escaping Redirects = { _, _ in true }) async throws -> (Data, URLResponse) {
        let reader = BoundedResponse(limit: limit, redirects: redirects)
        let task = session.dataTask(with: request)
        task.delegate = reader
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reader.lock.withLock { reader.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func finish(_ result: Result<(Data, URLResponse), any Error>) {
        let waiting = lock.withLock { () -> CheckedContinuation<(Data, URLResponse), any Error>? in
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard response.expectedContentLength <= limit else {
            finish(.failure(URLError(.dataLengthExceedsMaximum)))
            completionHandler(.cancel)
            return
        }
        lock.withLock { self.response = response }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let tooLong = lock.withLock { () -> Bool in
            body.append(data)
            return body.count > limit
        }
        guard tooLong else { return }
        finish(.failure(URLError(.dataLengthExceedsMaximum)))
        dataTask.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(redirects(response, request) ? request : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            finish(.failure(error))
            return
        }
        let (body, response) = lock.withLock { (self.body, self.response) }
        guard let response else { finish(.failure(URLError(.badServerResponse))); return }
        finish(.success((body, response)))
    }
}
