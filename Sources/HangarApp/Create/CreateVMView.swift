import SwiftUI
import UniformTypeIdentifiers

struct CreateVMView: View {
    static let width: CGFloat = 620
    static let minimumCardWidth: CGFloat = 200

    @Environment(\.dismiss) private var dismiss
    @State private var picked: Kind?
    @State private var template: URL?
    @State private var choosingTemplate = false
    private let startsPicked: Bool
    let created: (UUID) -> Void

    init(kind: Kind?, template: URL? = nil, created: @escaping (UUID) -> Void) {
        _picked = State(initialValue: kind)
        _template = State(initialValue: template)
        startsPicked = kind != nil || template != nil
        self.created = created
    }

    var body: some View {
        Group {
            if let template {
                TemplatePage(
                    url: template, back: startsPicked ? nil : { self.template = nil }, close: close, created: finish
                )
                .id(template)
            } else if let picked {
                KindPage(kind: picked, back: startsPicked ? nil : { self.picked = nil }, close: close, created: finish)
                    .id(picked)
            } else {
                KindPicker(close: close, openTemplate: { choosingTemplate = true }) { picked = $0 }
            }
        }
        .frame(width: Self.width)
        .fileImporter(isPresented: $choosingTemplate, allowedContentTypes: [.hangarTemplate]) { result in
            if case .success(let url) = result { template = url }
        }
    }

    private func close() {
        dismiss()
    }

    private func finish(_ id: UUID) {
        created(id)
        dismiss()
    }
}
