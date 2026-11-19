import Foundation
import HangarSupport

/// Hangar's latest release on GitHub, with the disk image the release workflow uploads to it.
package struct AppRelease: Equatable, Sendable {
    private static let latestURL = URL(constant: "https://api.github.com/repos/baseguard/hangar/releases/latest")
    private static let diskImageName = "Hangar.dmg"
    private static let responseLimit = 1 << 20
    private static let digestPrefix = "sha256:"
    private static let releasesPage = URL(constant: "https://github.com/baseguard/hangar/releases")

    package let version: AppVersion
    package let notesURL: URL
    let diskImage: URL
    /// The SHA-256 GitHub keeps of the disk image, in hex; `nil` for one uploaded before GitHub kept them.
    let diskImageDigest: String?

    @concurrent
    package static func latest() async throws -> AppRelease {
        let data = try await Downloader.data(from: latestURL, limit: responseLimit, kind: "Hangar's latest release")
        return try decode(data)
    }

    /// The fields of GitHub's release that Hangar reads.
    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let downloadURL: URL
            let digest: String?

            private enum CodingKeys: String, CodingKey {
                case name
                case downloadURL = "browser_download_url"
                case digest
            }
        }

        let tag: String
        let pageURL: URL
        let assets: [Asset]

        private enum CodingKeys: String, CodingKey {
            case tag = "tag_name"
            case pageURL = "html_url"
            case assets
        }
    }

    static func decode(_ data: Data) throws -> AppRelease {
        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw HangarError("GitHub's answer about Hangar's latest release can't be read.")
        }
        guard let version = AppVersion(release.tag) else {
            throw HangarError("Hangar's latest release, \(release.tag), isn't named like a version.")
        }
        guard let asset = release.assets.first(where: { $0.name == diskImageName }), asset.downloadURL.scheme == "https"
        else {
            throw HangarError("Hangar \(version) has no disk image to download yet; try again later.")
        }

        return AppRelease(
            version: version, notesURL: notesPage(release.pageURL), diskImage: asset.downloadURL,
            diskImageDigest: asset.digest.flatMap(sha256Hex))
    }

    /// The notes open in the browser, so only a page on github.com is taken; any other address shows all releases.
    private static func notesPage(_ url: URL) -> URL {
        url.scheme == "https" && url.host == "github.com" ? url : releasesPage
    }

    private static func sha256Hex(_ digest: String) -> String? {
        guard digest.hasPrefix(digestPrefix) else { return nil }
        return String(digest.dropFirst(digestPrefix.count))
    }
}
