import HangarKit
import HangarSupport
import SwiftUI

struct CopyProgressSheet: View {
    static let width: CGFloat = 400

    let copy: FileCopy
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.bezelSpacing) {
            Text("Copying \(copy.title) to “\(copy.vm)”")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            ProgressView(value: copy.fraction)
            HStack {
                Text("\(ByteSize.format(copy.copied)) of \(ByteSize.format(copy.total))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .scenePadding()
        .frame(width: Self.width)
    }
}
