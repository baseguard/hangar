import Foundation
import Testing

@testable import HangarKit

@Suite(.temporaryHangarHome)
struct RegistryClientTests {
    @Test func registriesAreAskedOnlyForTheAccessEachStepNeeds() async throws {
        let registry = try await StubRegistry()
        registry.requireToken()
        let credentials = RegistryCredentials(user: "octocat", token: "secret")
        let basic = "Basic " + Data("octocat:secret".utf8).base64EncodedString()
        let tagged = try registry.reference("hangar-macos:1.0")

        let digest = try await VMImage.push(try TestVM.make(.linux), to: [tagged], credentials: credentials) { _ in }

        let pushed = registry.tokenRequests
        #expect(
            !pushed.isEmpty
                && pushed.allSatisfy { $0.scope == "repository:hangar-macos:pull,push" && $0.authorization == basic })

        #expect(try await VMImage.pinned(tagged, credentials: credentials).digest == digest)

        let resolved = registry.tokenRequests.dropFirst(pushed.count)
        #expect(
            !resolved.isEmpty
                && resolved.allSatisfy { $0.scope == "repository:hangar-macos:pull" && $0.authorization == basic })

        _ = try await VMImage.pull(tagged.pinned(to: digest), named: "base") { _ in }

        let pulled = registry.tokenRequests.dropFirst(pushed.count + resolved.count)
        #expect(
            !pulled.isEmpty
                && pulled.allSatisfy { $0.scope == "repository:hangar-macos:pull" && $0.authorization == nil })
    }

    @Test func registriesThatOnlyChallengeAtTheirRootStillGetAToken() async throws {
        let registry = try await StubRegistry()
        registry.requireToken(likeHarbor: true)
        let credentials = RegistryCredentials(user: "octocat", token: "secret")
        let tagged = try registry.reference("hangar-macos:1.0")

        let digest = try await VMImage.push(try TestVM.make(.linux), to: [tagged], credentials: credentials) { _ in }
        let cached = try await VMImage.pull(tagged.pinned(to: digest), named: "base", credentials: credentials) { _ in }

        #expect(cached.config.os == .linux)
        #expect(!registry.tokenRequests.isEmpty && registry.tokenRequests.allSatisfy { $0.authorization != nil })
    }

    @Test func registriesWithBasicAuthGetTheSavedSignIn() async throws {
        let registry = try await StubRegistry()
        let credentials = RegistryCredentials(user: "octocat", token: "secret")
        registry.requireBasic(credentials.basic)
        let tagged = try registry.reference("hangar-macos:1.0")

        let digest = try await VMImage.push(try TestVM.make(.linux), to: [tagged], credentials: credentials) { _ in }

        #expect(
            try await VMImage.pull(tagged.pinned(to: digest), named: "base", credentials: credentials) { _ in }.config
                .os == .linux)
        #expect(
            await failureMessage { try await VMImage.inspect(tagged, credentials: nil) }
                == "\(tagged) was not found, or Hangar isn't allowed to use it.")
    }

    @Test func aSignInIsTriedBeforeItIsKept() async throws {
        let registry = try await StubRegistry()
        let right = RegistryCredentials(user: "octocat", token: "secret")
        let wrong = RegistryCredentials(user: "octocat", token: "typo")
        registry.requireBasic(right.basic)

        try await RegistryClient.checkSignIn(right, at: registry.host, plainHTTP: true)
        var message = ""
        do { try await RegistryClient.checkSignIn(wrong, at: registry.host, plainHTTP: true) } catch {
            message = error.localizedDescription
        }

        #expect(message == "\(registry.host) didn't accept octocat with that token, so it wasn't saved.")
    }

    @Test func aBusyTokenServerIsNotAWrongToken() async throws {
        let registry = try await StubRegistry()
        registry.requireToken()
        let credentials = RegistryCredentials(user: "octocat", token: "secret")

        registry.answerTokens(with: "503 Service Unavailable")
        let busy = await signInMessage(credentials, at: registry.host)
        registry.answerTokens(with: "401 Unauthorized")
        let refused = await signInMessage(credentials, at: registry.host)

        #expect(
            busy
                == "The sign-in wasn't saved: \(registry.host) couldn't sign Hangar in: its token server answered HTTP 503 without a token."
        )
        #expect(refused == "\(registry.host) didn't accept octocat with that token, so it wasn't saved.")
    }

    @Test func aRegistrysErrorAnswerReachesTheTerminalWithoutControlCharacters() {
        let body = Data("\u{1b}]52;c;aGk=\u{7}\u{1b}[2Jdown".utf8) + Data(repeating: UInt8(ascii: "x"), count: 1000)

        let detail = RegistryClient.errorDetail(body)

        #expect(detail.hasPrefix("?]52;c;aGk=??[2Jdown"))
        #expect(detail.utf8.count == 300)
    }

    private func signInMessage(_ credentials: RegistryCredentials, at host: String) async -> String {
        do {
            try await RegistryClient.checkSignIn(credentials, at: host, plainHTTP: true)
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    @Test func onlyTheRegistryItselfCanAskForTheSignIn() throws {
        let image = try ImageReference("ghcr.io/acme/ci:1.0")
        let local = try ImageReference("127.0.0.1:5005/acme/ci:1.0")

        #expect(RegistryClient.isRegistry(URL(string: "https://ghcr.io/v2/acme/ci/blobs/x"), of: image))
        #expect(!RegistryClient.isRegistry(URL(string: "https://pkg-containers.githubusercontent.com/blob"), of: image))
        #expect(!RegistryClient.isRegistry(URL(string: "https://ghcr.io:8443/v2/"), of: image))
        #expect(!RegistryClient.isRegistry(nil, of: image))
        #expect(RegistryClient.isRegistry(URL(string: "http://127.0.0.1:5005/v2/"), of: local))
        #expect(!RegistryClient.isRegistry(URL(string: "http://127.0.0.1:5006/v2/"), of: local))
    }

    @Test func registryNamesAreOnlyHosts() async throws {
        for good in ["ghcr.io", "127.0.0.1:5005", "quay.io", "docker.io", "localhost:5000"] {
            try RegistryCredentials.checkRegistry(good)
        }
        for bad in ["evil.com@ghcr.io", "ghcr.io/x", "ghcr", "-ghcr.io", "ghcr.io:99999999", "ghcr.io:port"] {
            #expect(throws: (any Error).self) { try RegistryCredentials.checkRegistry(bad) }
        }

        #expect(throws: (any Error).self) { try ImageReference("evil.com@ghcr.io/acme/ci:1.0") }
        #expect(try ImageReference("docker.io/acme/ci:1.0").apiHost == "registry-1.docker.io")
        #expect(try ImageReference("index.docker.io/acme/ci:1.0").apiHost == "index.docker.io")
        #expect(try ImageReference("ghcr.io/acme/ci:1.0").apiHost == "ghcr.io")
        #expect(
            RegistryClient.isRegistry(
                URL(string: "https://registry-1.docker.io/v2/"), of: try ImageReference("docker.io/acme/ci:1.0")))

        let both = try ImageReference("ghcr.io/acme/ci:1.0@sha256:" + String(repeating: "a", count: 64))
        #expect(try await VMImage.pinned(both, credentials: nil) == both)
    }

    @Test func plainHTTPStaysOnTheSameServer() throws {
        func follows(_ from: String, _ to: String) throws -> Bool {
            RegistryRedirects.follow(URLRequest(url: try #require(URL(string: to))), from: URL(string: from)) != nil
        }
        func authorization(_ from: String, _ to: String) throws -> String? {
            var request = URLRequest(url: try #require(URL(string: to)))
            request.setValue("Basic secret", forHTTPHeaderField: "Authorization")
            return RegistryRedirects.follow(request, from: URL(string: from))?.value(
                forHTTPHeaderField: "Authorization")
        }
        func accepts(_ realm: String, _ image: ImageReference) -> Bool {
            RegistryClient.acceptsTokenServer(URL(string: realm), for: image)
        }

        #expect(try !follows("http://r.example:5000/v2/x", "http://r.example:5001/v2/y"))
        #expect(try !follows("http://r.example:5000/v2/x", "http://cdn.example/blob"))
        #expect(try !follows("https://r.example/v2/x", "http://r.example/v2/y"))
        #expect(try authorization("http://r.example:5000/v2/x", "http://R.example:5000/v2/y") == "Basic secret")
        #expect(try authorization("http://r.example:5000/v2/x", "https://cdn.example/blob") == nil)
        #expect(try follows("http://r.example:5000/v2/x", "https://cdn.example/blob"))

        let digest = VMImage.digest(of: Data())
        let reference = try ImageReference("r.example:5000/ci:1.0", plainHTTP: true)
        #expect(
            reference.plainHTTP && reference.adding(digest: digest).plainHTTP
                && reference.pinned(to: digest).plainHTTP)
        #expect(reference.adding(digest: digest).description == "r.example:5000/ci:1.0@\(digest)")

        let secure = try ImageReference("r.example:5000/ci:1.0")
        #expect(!secure.plainHTTP)
        #expect(accepts("https://auth.example/token", secure) && accepts("https://auth.example/token", reference))
        #expect(accepts("http://r.example:5000/token", reference))
        #expect(!accepts("http://r.example:5000/token", secure))
        #expect(!accepts("http://r.example:5001/token", reference) && !accepts("http://auth.example/token", reference))
        #expect(!accepts("ftp://r.example:5000/token", reference))
    }

    @Test func anExpiredTokenIsRenewedAndTheRequestSentAgain() async throws {
        let registry = try await StubRegistry()
        let digest = try await registry.push(try TestVM.make(.linux))
        let part = try #require(try registry.manifest(digest).layers.first { $0.mediaType == VMImage.diskType })
        registry.requireToken()
        let client = RegistryClient(image: try registry.reference("hangar-macos@\(digest)"))
        _ = try await client.manifest(digest)

        registry.expireTokens()
        let manifest = try await client.manifest(digest)
        registry.expireTokens()
        try await client.streamBlob(part.digest, from: 0, begin: { _ in }, consume: { _ in })

        #expect(manifest.digest == digest)
        #expect(registry.tokenRequests.count == 3)
    }

    @Test func aFailedSignInIsTriedAgainByTheNextRequest() async throws {
        let registry = try await StubRegistry()
        let digest = try await registry.push(try TestVM.make(.linux))
        registry.requireToken()
        let credentials = RegistryCredentials(user: "octocat", token: "secret")
        let client = RegistryClient(image: try registry.reference("hangar-macos@\(digest)"), credentials: credentials)
        registry.answerTokens(with: "503 Service Unavailable")

        let busy = await #expect(throws: TemporaryFailure.self) { try await client.manifest(digest) }
        registry.answerTokens(with: "200 OK")
        let manifest = try await client.manifest(digest)

        #expect(
            busy?.message
                == "\(registry.host) couldn't sign Hangar in: its token server answered HTTP 503 without a token.")
        #expect(manifest.digest == digest)
    }

    @Test func aTokenServerOnAnotherPortIsRefused() async throws {
        let registry = try await StubRegistry()
        let other = try await StubRegistry()
        let digest = try await registry.push(try TestVM.make(.linux))
        registry.requireToken()
        registry.sendRealm(to: other.host)

        #expect(
            await failureMessage { try await registry.pull(digest) }
                == "\(registry.host) couldn't sign Hangar in: its token server isn't one Hangar may send the sign-in to."
        )

        #expect(other.tokenRequests.isEmpty)
    }

    @Test func referencesNeedATagOrDigest() throws {
        #expect(throws: (any Error).self) { try ImageReference("ghcr.io/baseguard/hangar-macos") }
        #expect(throws: (any Error).self) { try ImageReference("ghcr.io/baseguard/hangar-macos@sha256:abc") }
        #expect(try ImageReference("ghcr.io/baseguard/hangar-macos:index").tag == "index")
        #expect(!(try ImageReference("localhost:5000/hangar-macos:index")).plainHTTP)
    }
}
