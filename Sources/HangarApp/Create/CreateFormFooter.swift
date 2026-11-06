import SwiftUI

struct CreateFormFooter: View {
    let problem: String?
    let createTitle: LocalizedStringKey
    let close: () -> Void
    let create: () -> Void

    var body: some View {
        HStack {
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel", role: .cancel, action: close)
                .keyboardShortcut(.cancelAction)
            Button(createTitle, action: create)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(problem != nil)
        }
        .scenePadding()
    }
}
