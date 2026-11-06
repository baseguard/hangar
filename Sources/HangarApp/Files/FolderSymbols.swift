import HangarKit

/// Finder's sidebar symbols for the guest's places.
extension GuestPlace.Kind {
    var symbol: String {
        switch self {
        case .home: "house"
        case .drop: "tray.and.arrow.down"
        case .disk: "internaldrive"
        }
    }
}

extension FilesBrowser {
    /// The disk and the home keep their sidebar symbols in the path bar and the title's menu.
    func symbol(forFolderAt path: String) -> String {
        if disks.contains(where: { $0.path == path }) { return GuestPlace.Kind.disk.symbol }
        if path == homePath { return GuestPlace.Kind.home.symbol }
        return "folder"
    }
}
