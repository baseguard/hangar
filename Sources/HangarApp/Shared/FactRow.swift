import SwiftUI

struct FactRow<Value: View>: View {
    let title: String
    @ContentBuilder var value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            value
        }
    }
}
