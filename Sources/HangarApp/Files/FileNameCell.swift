import HangarKit
import SwiftUI

/// The Name column: the icon this Mac shows for the item's type, and its name. A name this Mac can't read exactly is
/// dimmed, because the item can't be copied.
struct FileNameCell: View {
    let file: GuestFile

    var body: some View {
        if file.isLossy {
            NameLabel(file: file)
                .opacity(Metrics.disabledOpacity)
                .help("This name can't be read exactly on this Mac.")
        } else {
            NameLabel(file: file)
        }
    }
}

private struct NameLabel: View {
    let file: GuestFile

    var body: some View {
        Label {
            Text(file.name)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            FileIcon(file: file)
        }
    }
}

/// A link carries an arrow badge, like a Finder alias.
private struct FileIcon: View {
    let file: GuestFile

    var body: some View {
        Image(nsImage: file.icon)
            .resizable()
            .frame(width: Metrics.listIconSize, height: Metrics.listIconSize)
            .overlay(alignment: .bottomLeading) {
                if file.isLink {
                    Image(systemName: "arrowshape.turn.up.right.circle.fill")
                        .font(.caption2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black)
                }
            }
    }
}
