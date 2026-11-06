import SwiftUI

struct KindBadge: View {
    let kind: CreateVMView.Kind
    var size = Metrics.controlSize

    var body: some View {
        if let os = kind.os {
            OSBadge(os: os, size: size)
        } else {
            SymbolBadge(systemImage: "shippingbox.fill", tint: .teal, size: size)
        }
    }
}
