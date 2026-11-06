import Foundation
import Network
import Testing

final class RedirectingServer: Sendable {
    private let listener: NWListener
    let url: URL

    init() async throws {
        let listener = try await NWListener.readyOnLoopback { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let reply =
                    String(decoding: data ?? Data(), as: UTF8.self).hasPrefix("GET /redirect ")
                    ? "HTTP/1.1 302 Found\r\nLocation: /plain.iso\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    : "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nplain"
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        self.listener = listener
        url = try #require(URL(string: "http://127.0.0.1:\(listener.port?.rawValue ?? 0)"))
    }

    deinit { listener.cancel() }
}
