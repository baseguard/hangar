import Foundation
import Network
import Synchronization
import Testing

@testable import HangarKit

final class StubRegistry: Sendable {
    struct TokenRequest: Sendable {
        let scope: String
        let authorization: String?
    }

    final class Store: Sendable {
        let blobs = Mutex<[String: Data]>([:])
        let corrupted = Mutex<Set<String>>([])
        let requiresToken = Mutex(false)
        let challengesOnlyAtRoot = Mutex(false)
        let basicAuthorization = Mutex<String?>(nil)
        let tokenRequests = Mutex<[TokenRequest]>([])
        let uploads = Mutex<[String: Data]>([:])
        let pieces = Mutex(0)
        let pieceLocationHost = Mutex<String?>(nil)
        let acceptsShort = Mutex(false)
        let ranges = Mutex<[String]>([])
        let rangeAnswer = Mutex(RangeAnswer.honour)
        let holdAfter = Mutex<Int?>(nil)
        let heldDownload = Mutex<NWConnection?>(nil)
        let realmHost = Mutex<String?>(nil)
        let tokenStatus = Mutex("200 OK")
        let tokenGeneration = Mutex(0)
    }

    enum RangeAnswer {
        case honour
        case ignore
        case wrongStart
    }

    private struct Reply {
        let bytes: Data
        var isHeld = false
    }

    private let listener: NWListener
    private let store: Store
    let host: String

    init() async throws {
        let store = Store()
        listener = try await NWListener.readyOnLoopback { connection in
            connection.start(queue: .global())
            Self.receive(on: connection, buffer: Data(), store: store)
        }
        self.store = store
        host = "127.0.0.1:\(listener.port?.rawValue ?? 0)"
    }

    deinit {
        listener.cancel()
        dropHeldDownload()
    }

    /// The stub speaks plain HTTP, which Hangar uses only with a registry marked insecure.
    func reference(_ path: String) throws -> ImageReference {
        try ImageReference("\(host)/\(path)", plainHTTP: true)
    }

    func stored(_ key: String) -> Data? { store.blobs.withLock { $0[key] } }
    var storedValues: [Data] { store.blobs.withLock { Array($0.values) } }
    func put(_ data: Data, at key: String) { store.blobs.withLock { $0[key] = data } }
    func corrupt(_ digest: String) { store.corrupted.withLock { _ = $0.insert(digest) } }
    func forget(_ key: String) { store.blobs.withLock { _ = $0.removeValue(forKey: key) } }
    func expireTokens() { store.tokenGeneration.withLock { $0 += 1 } }
    func requireBasic(_ authorization: String) { store.basicAuthorization.withLock { $0 = authorization } }

    func requireToken(likeHarbor: Bool = false) {
        store.requiresToken.withLock { $0 = true }
        store.challengesOnlyAtRoot.withLock { $0 = likeHarbor }
    }

    var tokenRequests: [TokenRequest] { store.tokenRequests.withLock { $0 } }
    var pieces: Int { store.pieces.withLock { $0 } }
    var ranges: [String] { store.ranges.withLock { $0 } }
    func movePieces(to host: String) { store.pieceLocationHost.withLock { $0 = host } }
    func acceptShort() { store.acceptsShort.withLock { $0 = true } }
    func answerRanges(_ answer: RangeAnswer) { store.rangeAnswer.withLock { $0 = answer } }
    func sendRealm(to host: String) { store.realmHost.withLock { $0 = host } }
    func answerTokens(with status: String) { store.tokenStatus.withLock { $0 = status } }

    /// The next blob download stops after `bytes` and stays open until `dropHeldDownload()`. Closing at once
    /// fails under load: URLSession drops body bytes that arrive together with the end of a cut-short response.
    func holdNextDownload(after bytes: Int) { store.holdAfter.withLock { $0 = bytes } }

    func dropHeldDownload() {
        let connection = store.heldDownload.withLock { held in
            defer { held = nil }
            return held
        }
        connection?.cancel()
    }

    private static func receive(on connection: NWConnection, buffer: Data, store: Store) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
            let received = buffer + (data ?? Data())
            if let end = received.firstRange(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: received[..<end.lowerBound], as: UTF8.self)
                let length =
                    head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = received[end.upperBound...]
                if body.count >= length {
                    let reply = respond(to: head, body: Data(body.prefix(length)), store: store)
                    send(reply, on: connection, store: store)
                    return
                }
            }
            guard !complete, error == nil else {
                connection.cancel()
                return
            }
            receive(on: connection, buffer: received, store: store)
        }
    }

    private static func send(_ reply: Reply, on connection: NWConnection, store: Store) {
        if reply.isHeld {
            store.heldDownload.withLock { $0 = connection }
            connection.send(content: reply.bytes, completion: .idempotent)
        } else {
            connection.send(content: reply.bytes, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private static func respond(to head: String, body: Data, store: Store) -> Reply {
        let words = head.split(separator: " ")
        let method = String(words[0])
        let target = URLComponents(string: String(words[1]))
        let path = target?.path ?? ""
        func reply(_ status: String, _ data: Data = Data(), headers: [String] = []) -> Reply {
            let lines =
                ["HTTP/1.1 \(status)", "Content-Length: \(method == "HEAD" ? 0 : data.count)", "Connection: close"]
                + headers
            return Reply(
                bytes: Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) + (method == "HEAD" ? Data() : data))
        }
        func header(_ name: String) -> String? {
            head.split(separator: "\r\n").dropFirst().first { $0.lowercased().hasPrefix("\(name):") }
                .map { $0.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces) }
        }
        if path == "/token" {
            let scope = target?.queryItems?.first { $0.name == "scope" }?.value ?? ""
            store.tokenRequests.withLock {
                $0.append(TokenRequest(scope: scope, authorization: header("authorization")))
            }
            let status = store.tokenStatus.withLock { $0 }
            guard status == "200 OK" else { return reply(status) }
            let token = "stub-token-\(store.tokenGeneration.withLock { $0 })"
            return reply("200 OK", Data(#"{"token":"\#(token)"}"#.utf8), headers: ["Set-Cookie: sid=stub; Path=/"])
        }
        if let basic = store.basicAuthorization.withLock({ $0 }), header("authorization") != basic {
            return reply("401 Unauthorized", headers: ["WWW-Authenticate: Basic realm=\"stub\""])
        }
        let likeHarbor = store.challengesOnlyAtRoot.withLock { $0 }
        if likeHarbor, header("cookie") != nil, method != "GET", method != "HEAD" {
            return reply("403 Forbidden")
        }
        let currentToken = "Bearer stub-token-\(store.tokenGeneration.withLock { $0 })"
        if store.requiresToken.withLock({ $0 }), header("authorization") != currentToken {
            if likeHarbor, path != "/v2/" { return reply(method == "HEAD" ? "404 Not Found" : "403 Forbidden") }
            let realm = "http://\(store.realmHost.withLock { $0 } ?? header("host") ?? "")/token"
            return reply(
                "401 Unauthorized",
                headers: [
                    "WWW-Authenticate: Bearer realm=\"\(realm)\",service=\"stub\"", "Set-Cookie: sid=stub; Path=/",
                ])
        }
        if path == "/v2/" { return reply("200 OK", Data("{}".utf8)) }
        if let range = path.range(of: "/blobs/uploads/") {
            if method == "POST" {
                return reply("202 Accepted", headers: ["Location: \(path[..<range.upperBound])\(UUID().uuidString)"])
            }
            let id = String(path[range.upperBound...])
            if method == "PATCH" {
                let received = store.uploads.withLock { uploads in
                    uploads[id, default: Data()].append(body)
                    return uploads[id]?.count ?? 0
                }
                store.pieces.withLock { $0 += 1 }
                let host = store.pieceLocationHost.withLock { $0 }.map { "http://\($0)" } ?? ""
                let end = received - (store.acceptsShort.withLock { $0 } ? 2 : 1)
                return reply("202 Accepted", headers: ["Location: \(host)\(path)", "Range: 0-\(end)"])
            }
            let whole = (store.uploads.withLock { $0.removeValue(forKey: id) } ?? Data()) + body
            guard let digest = target?.queryItems?.first(where: { $0.name == "digest" })?.value,
                VMImage.digest(of: whole) == digest
            else { return reply("400 Bad Request") }
            store.blobs.withLock { $0["blobs/\(digest)"] = whole }
            return reply("201 Created")
        }
        if let range = path.range(of: "/blobs/") {
            let digest = String(path[range.upperBound...])
            guard var data = store.blobs.withLock({ $0["blobs/\(digest)"] }) else { return reply("404 Not Found") }
            if store.corrupted.withLock({ $0.contains(digest) }), !data.isEmpty { data[data.startIndex] ^= 0xff }
            if method == "GET", let held = store.holdAfter.withLock({ $0 }), data.count > held {
                store.holdAfter.withLock { $0 = nil }
                let responseHead = "HTTP/1.1 200 OK\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
                return Reply(bytes: Data(responseHead.utf8) + data.prefix(held), isHeld: true)
            }
            guard let asked = header("range") else { return reply("200 OK", data) }
            store.ranges.withLock { $0.append(asked) }
            guard let start = asked.wholeMatch(of: /bytes=([0-9]+)-/).flatMap({ Int($0.1) }), start < data.count else {
                return reply("416 Range Not Satisfiable")
            }
            switch store.rangeAnswer.withLock({ $0 }) {
            case .ignore:
                return reply("200 OK", data)
            case .honour, .wrongStart:
                let from = store.rangeAnswer.withLock { $0 } == .wrongStart ? start + 1 : start
                return reply(
                    "206 Partial Content", data[from...],
                    headers: ["Content-Range: bytes \(from)-\(data.count - 1)/\(data.count)"])
            }
        }
        if let range = path.range(of: "/manifests/") {
            let reference = String(path[range.upperBound...])
            if method == "PUT" {
                store.blobs.withLock {
                    $0["manifests/\(reference)"] = body
                    $0["manifests/\(VMImage.digest(of: body))"] = body
                }
                return reply("201 Created")
            }
            guard let data = store.blobs.withLock({ $0["manifests/\(reference)"] }) else {
                return reply("404 Not Found")
            }
            return reply("200 OK", data, headers: ["Content-Type: \(RegistryClient.manifestType)"])
        }
        return reply("404 Not Found")
    }
}

extension StubRegistry {
    func push(_ bundle: VMBundle, tag: String = "base-27.0.1", snapshot: VMSnapshot? = nil) async throws -> String {
        let os = try bundle.loadConfig().os
        let details = os == .macOS ? try MacImage.details(of: bundle, build: TestVM.macOSBuild, xcode: nil) : nil
        return try await VMImage.push(
            bundle, snapshot: snapshot, to: [try reference("hangar-macos:\(tag)")],
            macOS: details, credentials: nil
        ) { _ in }
    }

    func pull(_ digest: String) async throws -> VMImage.Cached {
        try await VMImage.pull(try reference("hangar-macos@\(digest)"), named: "base") { _ in }
    }

    func manifest(_ digest: String) throws -> VMImage.Manifest {
        try JSONDecoder().decode(VMImage.Manifest.self, from: try #require(stored("manifests/\(digest)")))
    }
}
