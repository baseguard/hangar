import CryptoKit
import Foundation
import HangarSupport
import Synchronization

final class RegistryClient: BlobSource {
    static let manifestType = "application/vnd.oci.image.manifest.v1+json"
    /// ghcr.io can take over a minute to answer once a large part has arrived, past URLSession's 60 s default.
    static let uploadTimeout: TimeInterval = 300
    /// Answers that carry no blob (tokens, upload starts, errors) are read up to these; a detail is quoted in part.
    private static let smallReplyLimit = 64 << 10
    private static let uploadReplyLimit = 1 << 20
    private static let shownErrorBytes = 300

    static var withoutCookies: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return configuration
    }

    let image: ImageReference
    private let credentials: RegistryCredentials?
    private let pushes: Bool
    private let uploadChunkSize: Int
    private let session = URLSession(configuration: RegistryClient.withoutCookies)
    private let authorization = Mutex<String?>(nil)
    private let signingIn = Mutex<Task<Void, any Error>?>(nil)

    init(image: ImageReference, credentials: RegistryCredentials? = nil, pushes: Bool = false, uploadChunkSize: Int = 0)
    {
        self.image = image
        self.credentials = credentials
        self.pushes = pushes
        self.uploadChunkSize = uploadChunkSize
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    func manifest(_ tagOrDigest: String) async throws -> (data: Data, digest: String) {
        var request = URLRequest(url: try url("manifests/\(tagOrDigest)"))
        request.setValue(Self.manifestType, forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request, limit: VMImage.maximumManifest)
        guard (response.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix(Self.manifestType) else {
            throw HangarError("\(image.registry)/\(image.repository):\(tagOrDigest) is not a Hangar image.")
        }

        let digest = SHA256.hash(data: data).ociDigest
        if tagOrDigest.hasPrefix(Digests.prefix), tagOrDigest != digest {
            throw HangarError("The registry sent a manifest that does not match \(tagOrDigest).")
        }
        return (data, digest)
    }

    func manifest(digest: String) async throws -> Data {
        try await manifest(digest).data
    }

    func blob(_ digest: String, limit: Int) async throws -> Data {
        let (data, _) = try await send(URLRequest(url: try url("blobs/\(digest)")), limit: limit)
        guard SHA256.hash(data: data).ociDigest == digest else {
            throw HangarError("A download from \(image.registry) was corrupted (\(digest)).")
        }
        return data
    }

    func streamBlob(
        _ digest: String, from start: Int64, begin: @escaping @Sendable (BlobStart) throws -> Void,
        consume: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        try await signInFirst()
        var request = URLRequest(url: try url("blobs/\(digest)"))
        if start > 0 { request.setValue("bytes=\(start)-", forHTTPHeaderField: "Range") }
        for attempt in 0..<2 {
            switch try await BlobStream.run(authorized(request), begin: begin, consume: consume) {
            case .finished:
                return
            case .unauthorized(let challenge, let server) where attempt == 0:
                try await authenticate(challenge, from: server)
            case .unauthorized:
                throw denied
            }
        }
    }

    func hasBlob(_ digest: String) async throws -> Bool {
        var request = URLRequest(url: try url("blobs/\(digest)"))
        request.httpMethod = "HEAD"
        do {
            _ = try await send(request, limit: 0)
            return true
        } catch is Missing {
            return false
        }
    }

    func upload(_ data: Data, digest: String) async throws {
        guard try await !hasBlob(digest) else { return }

        var location = try await startUpload()
        var sent = 0

        while uploadChunkSize > 0, sent < data.count {
            let end = min(sent + uploadChunkSize, data.count)
            location = try await uploadPiece(data[sent..<end], to: location, from: sent)
            sent = end
        }

        guard var components = URLComponents(url: location, resolvingAgainstBaseURL: false) else {
            throw HangarError("\(image.registry) gave an upload address Hangar can't use.")
        }

        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "digest", value: digest)]
        guard let target = components.url else {
            throw HangarError("\(image.registry) gave an upload address Hangar can't use.")
        }

        var request = URLRequest(url: target, timeoutInterval: Self.uploadTimeout)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let rest = data[sent...]
        let (body, response) = try await session.upload(
            for: authorized(request), from: rest, delegate: RegistryRedirects.shared)
        try check(response, data: body, for: request)
    }

    private func uploadPiece(_ piece: Data, to location: URL, from start: Int) async throws -> URL {
        let end = start + piece.count - 1
        var request = URLRequest(url: location, timeoutInterval: Self.uploadTimeout)
        request.httpMethod = "PATCH"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("\(start)-\(end)", forHTTPHeaderField: "Content-Range")
        let (body, response) = try await session.upload(
            for: authorized(request), from: piece, delegate: RegistryRedirects.shared)
        try check(response, data: body, for: request)
        guard let http = response as? HTTPURLResponse,
            let range = http.value(forHTTPHeaderField: "Range")?.wholeMatch(of: /(?:bytes=)?0-([0-9]+)/),
            Int(range.1) == end
        else {
            throw HangarError(
                "\(image.registry) didn't take all of an upload piece; try again with a larger --chunk-size, or 0.")
        }

        return try uploadLocation(in: http)
    }

    func putManifest(_ data: Data, as tag: String) async throws {
        var request = URLRequest(url: try url("manifests/\(tag)"))
        request.httpMethod = "PUT"
        request.setValue(Self.manifestType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        _ = try await send(request, limit: Self.uploadReplyLimit)
    }

    private func startUpload() async throws -> URL {
        var start = URLRequest(url: try url("blobs/uploads/"))
        start.httpMethod = "POST"
        start.setValue("0", forHTTPHeaderField: "Content-Length")
        let (_, response) = try await send(start, limit: Self.uploadReplyLimit)
        return try uploadLocation(in: response)
    }

    private func uploadLocation(in response: HTTPURLResponse) throws -> URL {
        let base = try url("")
        guard let location = response.value(forHTTPHeaderField: "Location"),
            let resolved = URL(string: location, relativeTo: base)?.absoluteURL,
            resolved.scheme == base.scheme, Self.isRegistry(resolved, of: image)
        else {
            throw HangarError("\(image.registry) did not say where to upload.")
        }
        return resolved
    }

    struct Missing: Error {}

    /// The registry refused the sign-in or the access (HTTP 401 or 403), as opposed to failing.
    struct Denied: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var denied: Denied {
        guard pushes else { return Denied(message: "\(image) was not found, or Hangar isn't allowed to use it.") }
        return Denied(
            message:
                "\(image.registry) refused the push to \(image.repository); sign in with an account that may push there (hangar login)."
        )
    }

    /// The sign-in itself went wrong (a busy token server, a challenge Hangar won't follow), which says nothing
    /// about whether the account is allowed in.
    private func signInFailed(_ reason: String) -> HangarError {
        HangarError("\(image.registry) couldn't sign Hangar in: \(reason).")
    }

    private func url(_ path: String) throws -> URL {
        let scheme = image.plainHTTP ? "http" : "https"
        guard let url = URL(string: "\(scheme)://\(image.apiHost)/v2/\(image.repository)/\(path)") else {
            throw HangarError("\(image) is not a registry address Hangar can reach.")
        }
        return url
    }

    private func authorized(_ request: URLRequest) -> URLRequest {
        var request = request
        if let authorization = authorization.withLock({ $0 }) {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func signInFirst() async throws {
        let signIn = signingIn.withLock { started in
            if let started { return started }
            let signIn = Task { try await self.askForTokenUpFront() }
            started = signIn
            return signIn
        }
        do {
            try await signIn.value
        } catch {
            forgetFailed(signIn)
            throw error
        }
    }

    /// The next request signs in again, so a retry after a dropped connection or a busy token server can work.
    private func forgetFailed(_ signIn: Task<Void, any Error>) {
        signingIn.withLock { started in
            if started == signIn { started = nil }
        }
    }

    private func askForTokenUpFront() async throws {
        guard let ping = URL(string: "\(image.plainHTTP ? "http" : "https")://\(image.apiHost)/v2/") else { return }
        let (bytes, response) = try await session.bytes(for: URLRequest(url: ping), delegate: RegistryRedirects.shared)
        var read = 0

        for try await _ in bytes {
            read += 1
            if read > Self.smallReplyLimit { break }
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 401,
            let challenge = http.value(forHTTPHeaderField: "WWW-Authenticate")
        else { return }

        if credentials == nil {
            try? await authenticate(challenge, from: http.url)
        } else {
            try await authenticate(challenge, from: http.url)
        }
    }

    private func send(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        try await signInFirst()

        for attempt in 0..<2 {
            let (bytes, response) = try await session.bytes(
                for: authorized(request), delegate: RegistryRedirects.shared)
            guard let http = response as? HTTPURLResponse else {
                throw HangarError("\(image.registry) sent no HTTP response.")
            }

            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                guard data.count <= max(limit, Self.smallReplyLimit) else {
                    throw HangarError(
                        "\(image.registry) sent more than \(ByteSize.format(UInt64(limit))) where a small reply was expected."
                    )
                }
            }
            if http.statusCode == 401, attempt == 0 {
                try await authenticate(http.value(forHTTPHeaderField: "WWW-Authenticate") ?? "", from: http.url)
                continue
            }
            try check(http, data: data, for: request)
            return (data, http)
        }

        throw denied
    }

    private func check(_ response: URLResponse, data: Data, for request: URLRequest) throws {
        guard let http = response as? HTTPURLResponse else {
            throw HangarError("\(image.registry) sent no HTTP response.")
        }

        switch http.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw denied
        case 404 where request.httpMethod == "HEAD":
            throw Missing()
        case 404:
            throw HangarError("\(image) was not found.")
        default:
            let detail = Self.errorDetail(data)
            throw Self.failure(
                "\(image.registry) answered HTTP \(http.statusCode) for \(request.httpMethod ?? "GET") \(request.url?.path ?? "")\(detail.isEmpty ? "" : ": \(detail)").",
                status: http.statusCode)
        }
    }

    /// The start of a registry's error answer, without control characters, since it goes on to the user's terminal.
    static func errorDetail(_ body: Data) -> String {
        String(decoding: body.prefix(shownErrorBytes).withoutControlCharacters, as: UTF8.self)
    }

    /// A busy registry or token server (HTTP 5xx or 429) may answer when asked again; any other answer stays.
    static func failure(_ message: String, status: Int) -> any Error {
        if status == 429 || (500..<600).contains(status) { return TemporaryFailure(message) }
        return HangarError(message)
    }

    private func authenticate(_ challenge: String, from server: URL?) async throws {
        guard Self.isRegistry(server, of: image) else {
            throw signInFailed("the sign-in request came from another server")
        }

        if challenge.lowercased().hasPrefix("basic") {
            guard let credentials else { throw denied }
            authorization.withLock { $0 = credentials.basic }
            return
        }

        let request = try tokenRequest(for: challenge)
        let token = try await fetchToken(with: request)
        authorization.withLock { $0 = "Bearer \(token)" }
    }

    /// Asks the token server the registry names, and only one Hangar may send the sign-in to, for just the access
    /// this client needs.
    private func tokenRequest(for challenge: String) throws -> URLRequest {
        guard challenge.lowercased().hasPrefix("bearer ") else {
            throw signInFailed("it asks for a kind of sign-in Hangar doesn't know")
        }

        var fields: [String: String] = [:]
        for match in challenge.matches(of: /(\w+)="([^"]*)"/) {
            fields[match.1.lowercased()] = String(match.2)
        }
        guard let realm = fields["realm"], var components = URLComponents(string: realm),
            Self.acceptsTokenServer(components.url, for: image)
        else { throw signInFailed("its token server isn't one Hangar may send the sign-in to") }
        let actions = pushes ? "pull,push" : "pull"
        components.queryItems = [
            fields["service"].map { URLQueryItem(name: "service", value: $0) },
            URLQueryItem(name: "scope", value: "repository:\(image.repository):\(actions)"),
        ].compactMap { $0 }
        guard let tokenURL = components.url else { throw signInFailed("its token server address is broken") }

        var request = URLRequest(url: tokenURL)
        if let credentials {
            request.setValue(credentials.basic, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func fetchToken(with request: URLRequest) async throws -> String {
        let (bytes, response) = try await session.bytes(for: request, delegate: RegistryRedirects.shared)
        var data = Data()

        for try await byte in bytes {
            data.append(byte)
            guard data.count <= Self.smallReplyLimit else { throw signInFailed("its token answer is too long") }
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status != 401, status != 403 else { throw denied }
        guard status == 200, let answer = try? JSONDecoder().decode(TokenAnswer.self, from: data),
            let token = answer.token ?? answer.accessToken
        else {
            let refusal = signInFailed("its token server answered HTTP \(status) without a token")
            throw Self.failure(refusal.message, status: status)
        }
        return token
    }

    /// Tried before a sign-in is saved, so a mistyped token fails here and not at the first push. The
    /// registry's root takes any account it knows; the repository named here is never used.
    static func checkSignIn(_ credentials: RegistryCredentials, at registry: String, plainHTTP: Bool) async throws {
        let image = try ImageReference("\(registry)/sign-in:check", plainHTTP: plainHTTP)
        let client = RegistryClient(image: image, credentials: credentials)
        let scheme = client.image.plainHTTP ? "http" : "https"
        guard let root = URL(string: "\(scheme)://\(client.image.apiHost)/v2/") else {
            throw HangarError("\(registry) isn't a registry address Hangar can reach.")
        }

        do {
            _ = try await client.send(URLRequest(url: root), limit: smallReplyLimit)
        } catch is Denied {
            throw HangarError("\(registry) didn't accept \(credentials.user) with that token, so it wasn't saved.")
        } catch let error as URLError {
            throw HangarError("Could not reach \(registry), so the sign-in wasn't saved: \(error.localizedDescription)")
        } catch {
            // Hangar's own registry errors name the registry already.
            throw HangarError("The sign-in wasn't saved: \(error.localizedDescription)")
        }
    }

    static func acceptsTokenServer(_ realm: URL?, for image: ImageReference) -> Bool {
        guard let scheme = realm?.scheme?.lowercased() else { return false }
        return scheme == "https" || (scheme == "http" && image.plainHTTP && isRegistry(realm, of: image))
    }

    static func isRegistry(_ server: URL?, of image: ImageReference) -> Bool {
        guard let server, let registry = URLComponents(string: "//\(image.apiHost)") else { return false }
        return server.host?.lowercased() == registry.host?.lowercased() && server.port == registry.port
    }

    private struct TokenAnswer: Decodable {
        let token: String?
        let accessToken: String?

        enum CodingKeys: String, CodingKey {
            case token
            case accessToken = "access_token"
        }
    }
}
