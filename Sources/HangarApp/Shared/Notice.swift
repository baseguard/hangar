import SwiftUI

struct Notice: View {
    let text: String
    var systemImage = "info.circle.fill"
    var tint: Color = .secondary

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}
