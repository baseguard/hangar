import Foundation

extension URL {
    package init(userPath: String) {
        self.init(fileURLWithPath: (userPath as NSString).expandingTildeInPath)
    }
}
