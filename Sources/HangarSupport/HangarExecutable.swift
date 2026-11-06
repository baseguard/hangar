import Foundation
import Synchronization

/// Where the `hangar` command is, and the Hangar.app around it. Inside the app the command is a small app of its own,
/// `Contents/Helpers/HangarCLI.app`, so it can carry the provisioning profile its Keychain access group needs.
package enum HangarExecutable {
    /// Inside Hangar.app.
    package static let bundledPath = "Contents/Helpers/HangarCLI.app/Contents/MacOS/hangar"

    private static let location = Mutex(Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))

    package static var url: URL {
        get { location.withLock { $0 } }
        set { location.withLock { $0 = newValue } }
    }

    /// The outermost app the command is in, through a link like `/usr/local/bin/hangar`; `nil` for a command built
    /// on its own.
    package static var appBundle: URL? {
        var folder = url.resolvingSymlinksInPath().deletingLastPathComponent()
        var outermost: URL?
        while folder.path != "/" {
            if folder.pathExtension == "app" { outermost = folder }
            folder.deleteLastPathComponent()
        }
        return outermost
    }
}
