import SwiftUI

struct Fact: View {
    let title: String
    let value: String

    var body: some View {
        FactRow(title: title) {
            Text(value)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
