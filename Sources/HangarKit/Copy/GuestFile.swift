import Foundation

/// A file, folder or other item in a `GuestFolder`, named by the guest.
package struct GuestFile: Decodable, Equatable, Identifiable, Sendable {
    package enum Kind: String, Decodable, Sendable {
        case folder
        case file
        /// A device, socket or anything else that can't be copied.
        case other
    }

    package let name: String
    package let kind: Kind
    /// A link to a file or folder; copies leave links out.
    package let isLink: Bool
    /// Bytes; 0 for anything but a file.
    package let size: UInt64
    /// Nil when the guest doesn't know.
    package let modified: Date?
    /// The guest's name wasn't valid UTF-8 or UTF-16, so `name` only looks like it and can't name the item back.
    package let isLossy: Bool

    package var id: String { name }

    private enum CodingKeys: String, CodingKey {
        case name
        case kind
        case isLink = "link"
        case size
        case modified
        case isLossy = "lossy"
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(Kind.self, forKey: .kind)
        isLink = try container.decode(Bool.self, forKey: .isLink)
        size = try container.decode(UInt64.self, forKey: .size)
        let seconds = try container.decode(Int64.self, forKey: .modified)
        modified = seconds == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(seconds))
        // The agent writes "lossy" only on the entries it applies to.
        isLossy = try container.decodeIfPresent(Bool.self, forKey: .isLossy) ?? false
    }

    /// Folders first, then by name as Finder sorts them, so "file 2" comes before "file 10".
    static func isListedBefore(_ first: GuestFile, _ second: GuestFile) -> Bool {
        let firstIsFolder = first.kind == .folder
        let secondIsFolder = second.kind == .folder
        guard firstIsFolder == secondIsFolder else { return firstIsFolder }
        return first.name.localizedStandardCompare(second.name) == .orderedAscending
    }
}
