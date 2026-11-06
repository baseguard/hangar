import HangarKit
import HangarSupport
import HangarTraffic
import SwiftUI
import UniformTypeIdentifiers

struct TrafficRuleTransfer: View {
    @Environment(VMStore.self) private var store
    let vm: VMItem
    @State private var exporting = false
    @State private var importing = false
    @State private var askingAddress = false
    @State private var address = ""
    @State private var downloading = false
    @State private var pending: TrafficRuleFile?

    var body: some View {
        Section {
            HStack {
                if vm.config.traffic.enforces {
                    Text("Rules File")
                } else {
                    Notice(text: "These rules apply when the mode is Allow List or Block List.")
                }
                Spacer()
                RulesFileMenu(
                    downloading: downloading, importFile: { importing = true }, importFromURL: askForAddress,
                    export: { exporting = true })
            }
        }
        .fileExporter(
            isPresented: $exporting, document: TrafficRulesDocument(file: TrafficRuleFile(vm.config.traffic)),
            contentType: .json, defaultFilename: "\(vm.name) Traffic Rules"
        ) { result in
            if case .failure(let error) = result { store.report(error, doing: "export the traffic rules") }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { readFile($0) }
        .alert("Import Traffic Rules from a URL", isPresented: $askingAddress) {
            TextField("URL", text: $address, prompt: Text("https://…/rules.json"))
            Button("Import", action: download)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hangar downloads the file over https and asks before it changes anything.")
        }
        .modifier(ReplaceRulesConfirmation(vm: vm, pending: $pending))
    }

    private func askForAddress() {
        address = ""
        askingAddress = true
    }

    private func readFile(_ result: Result<URL, Error>) {
        Task {
            do {
                let url = try result.get()
                pending = try await runInBackground { try TrafficRuleFile.read(from: url) }
            } catch {
                store.report(error, doing: "import the traffic rules")
            }
        }
    }

    private func download() {
        let source = address
        downloading = true
        Task {
            defer { downloading = false }
            do {
                pending = try await TrafficRuleFile.download(from: source)
            } catch {
                store.report(error, doing: "import the traffic rules")
            }
        }
    }
}

private struct RulesFileMenu: View {
    let downloading: Bool
    let importFile: () -> Void
    let importFromURL: () -> Void
    let export: () -> Void

    var body: some View {
        HStack {
            if downloading {
                ProgressView().controlSize(.small)
            }
            Menu {
                Button("Import from URL…", action: importFromURL)
                    .disabled(downloading)
                Button("Export…", action: export)
            } label: {
                Label("Import…", systemImage: "square.and.arrow.down")
            } primaryAction: {
                importFile()
            }
            .fixedSize()
            .help(
                "Import or export the mode, the allowed and blocked hosts, and what the VM may reach, as a JSON file. Isolation isn't part of it."
            )
        }
    }
}

private struct ReplaceRulesConfirmation: ViewModifier {
    @Environment(VMStore.self) private var store
    let vm: VMItem
    @Binding var pending: TrafficRuleFile?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Replace the traffic rules of “\(vm.name)”?",
            isPresented: Binding(
                get: { pending != nil }, set: { if !$0 { pending = nil } }
            ), titleVisibility: .visible
        ) {
            Button("Replace") {
                if let file = pending { store.updateTraffic(vm.name) { try $0.apply(file) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let pending { Text(summary(pending)) }
        }
    }

    private func summary(_ file: TrafficRuleFile) -> String {
        file.summary + " The VM's isolation stays as it is."
    }
}

nonisolated struct TrafficRulesDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]

    let file: TrafficRuleFile

    init(file: TrafficRuleFile) {
        self.file = file
    }

    init(configuration: ReadConfiguration) throws {
        file = try TrafficRuleFile.decode(configuration.file.regularFileContents ?? Data())
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try file.encoded())
    }
}
