import AppKit
import Foundation
import HangarSupport

package enum RemoteDesktop {
    package static let clientURL = URL(constant: "https://apps.apple.com/app/windows-app/id1295203466")
    static func fileContents(user: String, address: String) -> String {
        let name = String(user.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        let settings = [
            "full address:s:\(address)",
            "username:s:\(name)",
            "screen mode id:i:1",
            "dynamic resolution:i:1",
            "audiomode:i:0",
            "audiocapturemode:i:1",
        ]
        return settings.joined(separator: "\r\n") + "\r\n"
    }

    package static func open(name: String, config: VMConfig, address: String) throws {
        guard config.remoteDesktop else {
            throw HangarError("Remote Desktop is off in '\(name)'; it was turned off when the VM was created.")
        }

        let file = try HangarPaths.createDirectory(HangarPaths.cache.appendingPathComponent("rdp", isDirectory: true))
            .appendingPathComponent("\(name).rdp")
        try fileContents(user: config.loginUser, address: address).write(to: file, atomically: true, encoding: .utf8)
        guard NSWorkspace.shared.urlForApplication(toOpen: file) != nil else {
            throw HangarError(
                "No Remote Desktop app is installed. Get Microsoft's Windows App: \(clientURL.absoluteString)")
        }
        guard NSWorkspace.shared.open(file) else {
            throw HangarError("Could not open \(file.path).")
        }
    }
}
