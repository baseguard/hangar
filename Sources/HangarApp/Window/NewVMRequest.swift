import Foundation

struct NewVMRequest: Identifiable {
    let id = UUID()
    var kind: CreateVMView.Kind?
    var template: URL?
}
