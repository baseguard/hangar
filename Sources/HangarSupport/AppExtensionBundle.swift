import Foundation

package enum AppExtensionBundle {
    /// The app an extension is bundled in, read from the extension's own path
    /// (…/Hangar.app/Contents/PlugIns/HangarShare.appex), so it can never be another copy of the app.
    package static func containingApp(of extensionURL: URL) -> URL? {
        let plugIns = extensionURL.deletingLastPathComponent()
        let contents = plugIns.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()

        guard extensionURL.pathExtension == "appex", plugIns.lastPathComponent == "PlugIns",
            contents.lastPathComponent == "Contents", app.pathExtension == "app"
        else { return nil }

        return app
    }
}
