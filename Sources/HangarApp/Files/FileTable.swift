import HangarKit
import SwiftUI
import UniformTypeIdentifiers

/// The folder's items like Finder's list view. Double-click opens a folder or downloads a file; rows drag out to
/// Finder; files dropped on a folder's row go into that folder, and anywhere else into the folder shown.
struct FileTable: View {
    @Bindable var browser: FilesBrowser
    let folder: GuestFolder

    var body: some View {
        Table(of: GuestFile.self, selection: $browser.selection, sortOrder: $browser.sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { file in
                FileNameCell(file: file)
            }
            TableColumn("Date Modified", value: \.modifiedForSorting) { file in
                DetailText(file.dateText)
            }
            TableColumn("Size", value: \.size) { file in
                DetailText(file.sizeText)
                    .monospacedDigit()
            }
            .alignment(.numeric)
            TableColumn("Kind", value: \.kindDescription) { file in
                DetailText(file.kindDescription)
            }
        } rows: {
            ForEach(browser.shownEntries) { file in
                GuestFileRow(browser: browser, file: file, folderPath: folder.path)
            }
            // NSTableView takes every drag over the list, so drops between rows and below the last one come here.
            .onInsert(of: [.fileURL]) { _, providers in
                browser.upload(providers, toFolderAt: folder.path)
            }
        }
        .alternatingRowBackgrounds()
        .contextMenu(forSelectionType: GuestFile.ID.self) { ids in
            FileMenuItems(browser: browser, ids: ids)
        } primaryAction: { ids in
            browser.openItems(ids)
        }
        .dropDestination(for: URL.self) { urls, session in
            // A drag out of a Files window is a copy to Finder, not an upload.
            guard session.localSession == nil else { return }
            browser.upload(urls, toFolderAt: folder.path)
        }
        .overlay {
            if browser.shownEntries.isEmpty, !browser.searchText.isEmpty {
                ContentUnavailableView.search(text: browser.searchText)
            }
        }
    }
}

/// A row drags out as a file promise. Files dropped on a folder's row go into that folder, and on any other row into
/// the folder shown.
private struct GuestFileRow: TableRowContent {
    let browser: FilesBrowser
    let file: GuestFile
    let folderPath: String

    @TableRowBuilder<GuestFile>
    var tableRowBody: some TableRowContent<GuestFile> {
        if file.kind == .folder {
            TableRow(file)
                .itemProvider { browser.dragProvider(for: file) }
                .dropDestination(for: URL.self) { urls in
                    browser.upload(urls, into: file)
                }
        } else {
            TableRow(file)
                .itemProvider { browser.dragProvider(for: file) }
                .dropDestination(for: URL.self) { urls in
                    browser.upload(urls, toFolderAt: folderPath)
                }
        }
    }
}

/// Date, size and kind, in Finder's quieter color.
private struct DetailText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}
