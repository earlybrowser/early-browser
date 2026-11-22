// SPDX-License-Identifier: MPL-2.0

import Foundation

/// A response body read as it arrives, in the network's own chunks, and never
/// more than `limit` bytes of it: a longer one is cancelled as soon as it
/// passes that, so a website can't make Early hold more. Reading it byte by
/// byte did the same at about twelve times the work.
final class BoundedResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Whether to follow a redirect to the new request.
    typealias Redirects = @Sendable (HTTPURLResponse, URLRequest) -> Bool
    typealias Output = (Data, URLResponse)

    private enum Completion {
        case unregistered
        case waiting(CheckedContinuation<Output, any Error>)
        case finished(Result<Output, any Error>)
    }

    private let limit: Int
    private let redirects: Redirects
    /// Guards what the session's queue and the caller share.
    private let lock = NSLock()
    private var body = Data()
    private var response: URLResponse?
    private var completion = Completion.unregistered
    private var exceededLimit = false

    init(limit: Int, redirects: @escaping Redirects = { _, _ in true }) {
        self.limit = limit
        self.redirects = redirects
    }

    static func load(_ request: URLRequest, in session: URLSession, limit: Int,
                     redirects: @escaping Redirects = { _, _ in true }) async throws -> Output {
        let reader = BoundedResponse(limit: limit, redirects: redirects)
        let task = session.dataTask(with: request)
        task.delegate = reader
        return try await withTaskCancellationHandler {
            try await reader.waitForCompletion(starting: task.resume)
        } onCancel: {
            task.cancel()
        }
    }

    func waitForCompletion(starting start: @Sendable () -> Void) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            let result = lock.withLock { () -> Result<Output, any Error>? in
                switch completion {
                case .finished(let result): return result
                case .waiting: preconditionFailure("A response can have only one waiter")
                case .unregistered:
                    completion = .waiting(continuation)
                    return nil
                }
            }
            if let result { continuation.resume(with: result) }
            else { start() }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let allow = lock.withLock {
            if case .finished = completion { return false }
            guard !exceededLimit else { return false }
            exceededLimit = response.expectedContentLength > limit
            if exceededLimit { return false }
            self.response = response
            return true
        }
        completionHandler(allow ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let tooLong = lock.withLock { () -> Bool in
            if case .finished = completion { return false }
            guard !exceededLimit else { return false }
            if data.count > limit - body.count {
                exceededLimit = true
                return true
            }
            body.append(data)
            return false
        }
        if tooLong { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(redirects(response, request) ? request : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let delivery = lock.withLock { () -> (CheckedContinuation<Output, any Error>, Result<Output, any Error>)? in
            if case .finished = completion { return nil }
            let result: Result<Output, any Error>
            if exceededLimit { result = .failure(URLError(.dataLengthExceedsMaximum)) }
            else if let error { result = .failure(error) }
            else if let response { result = .success((body, response)) }
            else { result = .failure(URLError(.badServerResponse)) }

            // Cancellation can complete before the caller installs its waiter.
            // Keep the result and wait for this callback even on size rejection,
            // so callers don't free a network slot while the task is cancelling.
            let previous = completion
            completion = .finished(result)
            body = Data()
            response = nil
            if case .waiting(let waiter) = previous { return (waiter, result) }
            return nil
        }
        if let (waiter, result) = delivery { waiter.resume(with: result) }
    }
}
