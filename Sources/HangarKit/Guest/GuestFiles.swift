import Foundation
import HangarSupport

enum GuestFiles {
    static func data(_ path: String) throws -> Data {
        for folder in folders {
            if let data = try? Data(contentsOf: folder.appendingPathComponent(path)) { return data }
        }
        throw HangarError("Hangar's guest files are missing (Guest/\(path)). Reinstall Hangar.")
    }

    static func text(_ path: String) throws -> String {
        guard let text = String(data: try data(path), encoding: .utf8) else {
            throw HangarError("Hangar's guest file Guest/\(path) is damaged. Reinstall Hangar.")
        }
        return text
    }

    /// The app's resources; in tests, those of the loaded test bundle, which carries the same Guest folder.
    private static var folders: [URL] {
        let appResources = HangarExecutable.appBundle?.appendingPathComponent("Contents/Resources")
        let loadedResources = Bundle.allBundles.map(\.resourceURL)
        return ([appResources] + loadedResources).compactMap { $0?.appendingPathComponent("Guest", isDirectory: true) }
    }
}
