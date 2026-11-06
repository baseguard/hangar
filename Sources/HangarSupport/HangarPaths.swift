import Darwin
import Foundation
import Synchronization

package enum HangarPaths {
    @TaskLocal package static var homeOverride: URL?

    package static var home: URL {
        if let homeOverride { return homeOverride }
        if let custom = ProcessInfo.processInfo.environment["HANGAR_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }

        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hangar", isDirectory: true)
        securePrivateHome(url)
        return url
    }

    package static var vms: URL { home.appendingPathComponent("vms", isDirectory: true) }
    package static var network: URL { home.appendingPathComponent("network", isDirectory: true) }
    package static var cache: URL { home.appendingPathComponent("cache", isDirectory: true) }
    package static var ipswCache: URL { cache.appendingPathComponent("ipsw", isDirectory: true) }
    package static var isoCache: URL { cache.appendingPathComponent("iso", isDirectory: true) }

    @discardableResult
    package static func createDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return url
    }

    private static let securedHome = Mutex<String?>(nil)

    static func securePrivateHome(_ url: URL) {
        securedHome.withLock { secured in
            guard secured != url.path else { return }
            var info = stat()
            guard stat(url.path, &info) == 0 else { return }
            secured = url.path
            if info.st_mode & 0o077 != 0 { chmod(url.path, 0o700) }
        }
    }
}
