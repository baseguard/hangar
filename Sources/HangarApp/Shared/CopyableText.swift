import SwiftUI

struct CopyableText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack {
            Text(text)
                .monospaced()
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            CopyButton(text: text)
        }
    }
}
