// SPDX-License-Identifier: MPL-2.0

import Foundation
import Network

/// A loopback-only HTTP fixture for one downloadable file. The first full
/// request sends part of the body and stalls, so a test can stop the transfer;
/// a byte-range request (WebKit's resume) receives the remainder. No outside
/// network is used.
final class LocalHTTPServer: @unchecked Sendable {
    let body: Data
    private let initialChunk: Int
    private let listener: NWListener
    private let queue = DispatchQueue(label: "local.early.tests.http")
    private var connections: [NWConnection] = []
    private(set) var port: UInt16 = 0

    init(body: Data, initialChunk: Int) throws {
        self.body = body
        self.initialChunk = initialChunk
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    var url: URL { URL(string: "http://127.0.0.1:\(port)/large.bin")! }

    func stop() {
        queue.sync {
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            var start = 0
            if let range = request.range(of: #"(?i)range:\s*bytes=(\d+)-"#, options: .regularExpression) {
                start = Int(request[range].filter(\.isNumber)) ?? 0
            }
            let remainder = self.body.subdata(in: min(start, self.body.count)..<self.body.count)
            var headers = start > 0 ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
            headers += "Content-Type: application/octet-stream\r\n"
            headers += "Content-Disposition: attachment; filename=\"large.bin\"\r\n"
            headers += "Accept-Ranges: bytes\r\nETag: \"early-fixture\"\r\n"
            headers += "Last-Modified: Wed, 21 Oct 2026 07:28:00 GMT\r\n"
            headers += "Content-Length: \(remainder.count)\r\n"
            if start > 0 { headers += "Content-Range: bytes \(start)-\(self.body.count - 1)/\(self.body.count)\r\n" }
            headers += "Connection: close\r\n\r\n"
            var payload = Data(headers.utf8)
            if start > 0 {
                payload.append(remainder)
                connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
            } else {
                // Stall after the first chunk until the test stops the transfer.
                payload.append(remainder.prefix(self.initialChunk))
                connection.send(content: payload, completion: .contentProcessed { _ in })
            }
        }
    }
}
