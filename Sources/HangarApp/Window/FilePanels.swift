import AppKit
import UniformTypeIdentifiers

/// The file panels behind the menus, the settings page and the export sheet; callers only get what was chosen.
enum FilePanels {
    struct ChosenFolders {
        let urls: [URL]
        let isReadOnly: Bool
    }

    static func chooseISO(for name: String) -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Choose an ISO to attach to \(name)."
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .data, .diskImage]
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func chooseImageFile(named fileName: String) -> URL? {
        let panel = NSSavePanel()
        panel.message = "Choose where to save the image."
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = [.tarArchive]
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func chooseTrafficLogFile(for name: String) -> URL? {
        let panel = NSSavePanel()
        panel.message = "Choose where to save the traffic log of \(name)."
        panel.nameFieldStringValue = "\(name) Traffic.jsonl"
        panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .json]
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func chooseDownloadFolder(for name: String) -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Choose where to download the items from \(name)."
        panel.prompt = "Download"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func chooseUploadItems(for name: String, into folder: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.message = "Choose files and folders to upload to \(folder) in \(name)."
        panel.prompt = "Upload"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }

    static func chooseSharedFolders(for name: String) -> ChosenFolders? {
        let panel = NSOpenPanel()
        panel.message = "Choose folders to share with \(name)."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true

        let access = NSPopUpButton()
        access.addItems(withTitles: ["Read and Write", "Read Only"])
        let row = NSStackView(views: [NSTextField(labelWithString: "Access:"), access])
        row.spacing = Metrics.spacing
        row.edgeInsets = NSEdgeInsets(
            top: Metrics.bezelSpacing, left: Metrics.bezelSpacing,
            bottom: Metrics.bezelSpacing, right: Metrics.bezelSpacing)
        panel.accessoryView = row
        panel.isAccessoryViewDisclosed = true

        guard panel.runModal() == .OK else { return nil }
        return ChosenFolders(urls: panel.urls, isReadOnly: access.indexOfSelectedItem == 1)
    }
}
