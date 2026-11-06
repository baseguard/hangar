import HangarKit
import SwiftUI

struct OSBadge: View {
    var os: GuestOS
    var size = Metrics.controlSize

    var body: some View {
        SymbolBadge(systemImage: os.symbolName, tint: os.tint, size: size)
    }
}
