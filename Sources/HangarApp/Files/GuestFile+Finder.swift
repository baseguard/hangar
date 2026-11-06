import AppKit
import HangarKit
import UniformTypeIdentifiers

/// How Finder's list view shows an item: its icon, kind, date and size.
extension GuestFile {
    /// Finder's own date style: "Today at 10:31", "Yesterday at 09:12", then the date.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    /// Icons by content type: a folder of thousands of files asks for few of them.
    private static var icons: [UTType: NSImage] = [:]

    /// The type this Mac knows the item by, from its name's extension; the guest doesn't say.
    nonisolated var contentType: UTType {
        switch kind {
        case .folder: .folder
        case .file: UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
        case .other: .item
        }
    }

    /// A name without a known extension, like .bashrc, has only the generic data type, which Finder calls Document.
    private nonisolated var hasKnownType: Bool {
        !contentType.isDynamic && contentType != .data
    }

    nonisolated var kindDescription: String {
        guard !isLink else { return "Alias" }
        switch kind {
        case .folder: return "Folder"
        case .file: return hasKnownType ? contentType.localizedDescription ?? "Document" : "Document"
        case .other: return "Special File"
        }
    }

    var icon: NSImage {
        if let cached = Self.icons[contentType] { return cached }
        let image = NSWorkspace.shared.icon(for: contentType)
        Self.icons[contentType] = image
        return image
    }

    var dateText: String {
        guard let modified else { return "--" }
        return Self.dateFormatter.string(from: modified)
    }

    var sizeText: String {
        guard kind == .file else { return "--" }
        return Self.sizeFormatter.string(fromByteCount: Int64(clamping: size))
    }

    /// For sorting by date: an item without one sorts as the oldest.
    nonisolated var modifiedForSorting: Date { modified ?? .distantPast }
}
