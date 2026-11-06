import HangarKit
import SwiftUI

/// Finder's sidebar for the VM: its home and standard folders under Favorites, its disk under Locations. Choosing one
/// opens it; files dropped on one are uploaded into it.
struct FilesSidebar: View {
    let browser: FilesBrowser

    var body: some View {
        List(selection: selectedPlace) {
            if !browser.favorites.isEmpty {
                Section("Favorites") {
                    PlaceRows(browser: browser, places: browser.favorites)
                }
            }
            Section("Locations") {
                PlaceRows(browser: browser, places: browser.disks)
            }
        }
    }

    /// The place whose folder is shown is selected, as in Finder.
    private var selectedPlace: Binding<String?> {
        Binding {
            browser.folder?.path
        } set: { path in
            guard let path, path != browser.folder?.path else { return }
            browser.open(path)
        }
    }
}

private struct PlaceRows: View {
    let browser: FilesBrowser
    let places: [GuestPlace]

    var body: some View {
        ForEach(places) { place in
            Label(place.name, systemImage: place.kind.symbol)
                .tag(Optional(place.path))
                .dropDestination(for: URL.self) { urls, session in
                    // A drag out of a Files window is a copy to Finder, not an upload.
                    guard session.localSession == nil else { return }
                    browser.upload(urls, toFolderAt: place.path)
                }
        }
    }
}
