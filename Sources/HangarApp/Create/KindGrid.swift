import SwiftUI

struct KindGrid: View {
    let pick: (CreateVMView.Kind) -> Void

    var body: some View {
        CardGrid(minColumnWidth: CreateVMView.minimumCardWidth, maxColumns: 2, spacing: Metrics.bezelSpacing) {
            ForEach(CreateVMView.Kind.allCases) { kind in
                KindCard(kind: kind) { pick(kind) }
            }
        }
    }
}

private struct KindCard: View {
    static let minimumHeight: CGFloat = 100

    let kind: CreateVMView.Kind
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Metrics.bezelSpacing) {
                KindBadge(kind: kind, size: Metrics.extraLargeControlSize)
                VStack(alignment: .leading) {
                    Text(kind.title).font(.headline)
                    Text(kind.blurb)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding()
            .frame(maxWidth: .infinity, minHeight: Self.minimumHeight, maxHeight: .infinity, alignment: .topLeading)
            .background(.background.secondary, in: .rect(cornerRadius: Metrics.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                    .strokeBorder(
                        hovering ? Color.accentColor : Color.primary.opacity(0.06),
                        lineWidth: hovering ? Metrics.lineWidth : Metrics.hairline)
            }
            .contentShape(.rect(cornerRadius: Metrics.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityHint(kind.blurb)
    }
}
