import HangarKit
import SwiftUI

/// Asks where to save the template of `saving`'s VM.
struct SaveTemplateExporter: ViewModifier {
    @Environment(VMStore.self) private var store
    @Binding var saving: String?

    func body(content: Content) -> some View {
        content.fileExporter(
            isPresented: isPresented($saving), document: document, contentType: .hangarTemplate,
            defaultFilename: saving
        ) { result in
            if case .failure(let error) = result { store.report(error, doing: "save the template") }
        }
    }

    private var document: TemplateDocument? {
        guard let saving, let vm = store.vm(saving) else { return nil }
        return TemplateDocument(template: VMTemplate(savedFrom: vm.config, diskSize: vm.bundle.diskSize))
    }
}
