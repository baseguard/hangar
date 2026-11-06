import Foundation

/// One folder in a VM as the guest agent's `ls` lists it. Paths are in the guest's own form, like /home/dev or
/// C:\Users\dev.
package struct GuestFolder: Decodable, Equatable, Sendable {
    package let path: String
    /// Nil at a top folder, such as / or C:\.
    package let parent: String?
    /// The agent lists at most so many entries; the rest of a larger folder is left out.
    package let isTruncated: Bool
    package var entries: [GuestFile]

    private enum CodingKeys: String, CodingKey {
        case path
        case parent
        case isTruncated = "truncated"
        case entries
    }
}
