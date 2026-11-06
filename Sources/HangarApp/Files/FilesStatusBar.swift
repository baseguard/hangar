import HangarKit
import HangarSupport
import SwiftUI

/// Finder's path bar above its status bar: the way down to the folder shown, then how many items it has, or the
/// copies that run with their progress and Cancel.
struct FilesStatusBar: View {
    let browser: FilesBrowser

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if browser.folder != nil {
                FilesPathBar(browser: browser)
                    .frame(minHeight: Metrics.regularControlSize)
                    .padding(.horizontal, Metrics.bezelSpacing)
                Divider()
            }
            HStack(spacing: Metrics.spacing) {
                if let transfer = browser.transfers.summary {
                    TransferProgress(transfer: transfer) { browser.transfers.cancelAll() }
                } else {
                    FolderSummary(browser: browser)
                }
            }
            .frame(minHeight: Metrics.regularControlSize)
            .padding(.horizontal, Metrics.bezelSpacing)
        }
        .font(.callout)
        .background(.bar)
    }
}

/// Centered, as in Finder: "12 items" or "2 of 12 selected", then how the last copy ended.
private struct FolderSummary: View {
    let browser: FilesBrowser

    var body: some View {
        Text(summary)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                if browser.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
    }

    private var summary: String {
        guard let folder = browser.folder else { return "" }
        let count = browser.shownEntries.count
        let selected = browser.selection.count
        let items = "\(count) \(counted(count, "item"))"
        let shown = selected > 0 ? "\(selected) of \(count) selected" : items
        // A search shows fewer than the listing holds; the cut is the listing's.
        let listedCount = folder.entries.count
        let truncated = "Only the first \(listedCount) \(counted(listedCount, "item")) are listed"
        let listed = folder.isTruncated ? truncated : shown
        return [listed, browser.lastOutcome].compactMap(\.self).joined(separator: " · ")
    }
}

private struct TransferProgress: View {
    let transfer: FileTransfer
    let cancel: () -> Void

    var body: some View {
        Text(transfer.description + "…")
            .lineLimit(1)
            .truncationMode(.middle)
        if let fraction = transfer.fraction {
            ProgressView(value: fraction)
                .controlSize(.small)
            Text("\(ByteSize.format(transfer.copied)) of \(ByteSize.format(transfer.total))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .controlSize(.small)
        }
        Button("Cancel", role: .cancel, action: cancel)
            .controlSize(.small)
    }
}
