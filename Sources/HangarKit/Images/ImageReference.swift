import Foundation
import HangarSupport

package struct ImageReference: Hashable, Sendable, CustomStringConvertible {
    package let registry: String
    package let repository: String
    package let tag: String?
    package let digest: String?
    package let plainHTTP: Bool

    package static let plainHTTPWarning =
        "Plain HTTP: anyone on the network can read your sign-in and change which image a tag "
        + "points to. Every part is still checked against the image's digest."

    package init(_ text: String, plainHTTP: Bool = false) throws {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = HangarError("'\(value)' is not an image like ghcr.io/acme/ci-linux:1.0.")
        guard let slash = value.firstIndex(of: "/") else { throw invalid }

        let host = String(value[..<slash])
        guard

            host.wholeMatch(
                of:
                    /[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*(?::[0-9]{1,5})?/
            ) != nil,
            host.contains(".") || host.contains(":") || host == "localhost"
        else { throw invalid }
        var path = String(value[value.index(after: slash)...])
        var digest: String?
        if let at = path.firstIndex(of: "@") {
            digest = String(path[path.index(after: at)...])
            path = String(path[..<at])
        }

        var tag: String?
        if let colon = path.lastIndex(of: ":") {
            tag = String(path[path.index(after: colon)...])
            path = String(path[..<colon])
        }

        guard

            path.wholeMatch(of: /[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*(?:\/[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*)*/)
                != nil
        else {
            throw invalid
        }
        if let tag, tag.wholeMatch(of: /[A-Za-z0-9_][A-Za-z0-9._-]{0,127}/) == nil { throw invalid }
        if let digest, !Digests.isValid(digest) { throw invalid }
        guard tag != nil || digest != nil else { throw invalid }

        self.init(registry: host, repository: path, tag: tag, digest: digest, plainHTTP: plainHTTP)
    }

    private init(registry: String, repository: String, tag: String?, digest: String?, plainHTTP: Bool) {
        self.registry = registry
        self.repository = repository
        self.tag = tag
        self.digest = digest
        self.plainHTTP = plainHTTP
    }

    package var description: String {
        "\(registry)/\(repository)" + (tag.map { ":\($0)" } ?? "") + (digest.map { "@\($0)" } ?? "")
    }

    var tagOrDigest: String { digest ?? tag ?? "" }

    var apiHost: String {
        registry.lowercased() == "docker.io" ? "registry-1.docker.io" : registry
    }

    func pinned(to digest: String) -> ImageReference {
        ImageReference(registry: registry, repository: repository, tag: nil, digest: digest, plainHTTP: plainHTTP)
    }

    func adding(digest: String) -> ImageReference {
        ImageReference(registry: registry, repository: repository, tag: tag, digest: digest, plainHTTP: plainHTTP)
    }
}
