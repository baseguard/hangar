import Foundation

package enum HangarVersion {
    package static var current: String {
        let candidates = [HangarExecutable.appBundle, Bundle.main.bundleURL].compactMap { $0 }
        for url in candidates where url.pathExtension == "app" {
            if let version = Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String {
                return version
            }
        }
        return "dev"
    }
}
