import SwiftUI

struct Card<Content: View, Accessory: View>: View {
    var title: String?
    var systemImage: String?
    @ContentBuilder var content: Content
    @ContentBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.bezelSpacing) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    Label(title, systemImage: systemImage ?? "circle")
                        .labelStyle(CardTitleLabelStyle(showsIcon: systemImage != nil))
                    Spacer()
                    accessory
                        .buttonStyle(.link)
                }
            }
            content
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: .rect(cornerRadius: Metrics.cornerRadius, style: .continuous))
    }
}

extension Card where Accessory == EmptyView {
    init(title: String? = nil, systemImage: String? = nil, @ContentBuilder content: () -> Content) {
        self.init(title: title, systemImage: systemImage, content: content, accessory: { EmptyView() })
    }
}

private struct CardTitleLabelStyle: LabelStyle {
    let showsIcon: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            if showsIcon { configuration.icon.foregroundStyle(.secondary) }
            configuration.title
        }
        .font(.headline)
    }
}
