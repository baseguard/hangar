import Foundation

struct MainWindowRequest: Identifiable {
    enum Kind {
        case newVM(CreateVMView.Kind?)
        case newVMFromTemplate(URL)
        case page(vm: String, page: VMDetailView.Page)
        case dialog(VMDialog)
    }

    let id = UUID()
    let kind: Kind
}
