import AppKit
import HangarKit
import SwiftUI

struct VMManageActions: View {
    let vm: VMItem
    var managesLibrary = false

    var body: some View {
        if managesLibrary {
            Section {
                Button("Rename…") { VMDialog.rename(vm.name).post() }
                    .disabled(vm.isRunning)
                Button("Clone…") { VMDialog.clone(vm.name).post() }
                    .disabled(vm.isRunning)
            }
            Section {
                Button("Export…") { VMDialog.export(vm.name).post() }
                    .disabled(vm.isRunning)
                Button("Save as Template…") { VMDialog.saveTemplate(vm.name).post() }
            }
        }
        Section {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([vm.bundle.url]) }
        }
        if managesLibrary {
            Section {
                Button(role: .destructive) {
                    VMDialog.delete(vm.name).post()
                } label: {
                    Text("Delete…").foregroundStyle(.red)
                }
                .disabled(vm.isRunning)
            }
        }
    }
}
