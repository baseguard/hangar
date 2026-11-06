import Foundation

/// Files shared to Hangar, waiting for the user to pick the VM to drop them into.
struct DropRequest: Identifiable {
    let id = UUID()
    let files: [URL]
}
