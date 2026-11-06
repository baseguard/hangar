import HangarKit
import SwiftUI

private enum ExportPlace: Hashable {
    case registry
    case file
}

struct ExportSheet: View {
    static let width: CGFloat = 520

    @Environment(VMStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let target: ExportTarget
    @State private var place = ExportPlace.registry
    @State private var reference = ""
    @State private var file: URL?
    @State private var canReplaceFile = false
    @State private var job = ExportJob()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(target.snapshot.map { "Export “\($0.name)” of “\(target.vm)”" } ?? "Export “\(target.vm)”")
                .font(.title3.weight(.semibold))
                .scenePadding()
            ExportForm(
                target: target, place: $place, reference: $reference, file: file, job: job,
                note: busyNote, chooseFile: chooseFile)
            ExportButtons(
                job: job, canExport: destination != nil && busyNote == nil, export: export, dismiss: { dismiss() }
            )
            .scenePadding()
        }
        .frame(width: Self.width)
        .interactiveDismissDisabled(job.isRunning)
    }

    /// Said in the sheet itself, since an alert would only show once the sheet is gone.
    private var busyNote: String? {
        guard !job.isRunning, store.busy.contains(target.vm) else { return nil }
        return "“\(target.vm)” is busy with another task; export it when that has finished."
    }

    private var destination: ExportJob.Destination? {
        switch place {
        case .registry: pushTarget.map { .registry($0) }
        case .file: file.map { .file($0, replacing: canReplaceFile) }
        }
    }

    private var pushTarget: ImageReference? {
        guard let parsed = try? ImageReference(reference), parsed.tag != nil, parsed.digest == nil else { return nil }
        return parsed
    }

    private var suggestedFileName: String {
        let name = target.snapshot.map { "\(target.vm)-\($0.name)" } ?? target.vm
        return name + ".tar"
    }

    /// The save panel asked before replacing only the file there now, so only that one may be replaced; one that
    /// appears later is refused. The export takes its place once finished, so a failed or cancelled one keeps it.
    private func chooseFile() {
        guard let chosen = FilePanels.chooseImageFile(named: suggestedFileName) else { return }
        file = chosen
        canReplaceFile = FileManager.default.fileExists(atPath: chosen.path)
    }

    private func export() {
        if let destination { job.start(target, to: destination) }
    }
}

private struct ExportForm: View {
    let target: ExportTarget
    @Binding var place: ExportPlace
    @Binding var reference: String
    let file: URL?
    let job: ExportJob
    let note: String?
    let chooseFile: () -> Void

    var body: some View {
        Form {
            DestinationSection(place: $place, reference: $reference, file: file, chooseFile: chooseFile)
                .disabled(job.isRunning || job.exported != nil)
            Section {
                Text(VMImage.wholeDiskWarning)
                if target.snapshot != nil { Text(VMImage.runningSnapshotWarning) }
            } header: {
                Text("What goes into the image")
            }
            if let line = job.progress ?? job.problem ?? note {
                Section { Text(line).foregroundStyle(job.progress == nil ? .secondary : .primary) }
            }
            if let exported = job.exported {
                switch exported {
                case .pushed(let pushed):
                    PushedImageSection(pushed: pushed, os: target.os, reference: reference)
                case .saved(let saved):
                    SavedFileSection(file: saved, os: target.os)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct DestinationSection: View {
    @Binding var place: ExportPlace
    @Binding var reference: String
    let file: URL?
    let chooseFile: () -> Void

    var body: some View {
        Section {
            Picker("Export to", selection: $place) {
                Text("Registry").tag(ExportPlace.registry)
                Text("File").tag(ExportPlace.file)
            }
            .pickerStyle(.segmented)
            switch place {
            case .registry:
                TextField("Push to", text: $reference, prompt: Text("ghcr.io/acme/ci-linux:1.0"))
            case .file:
                LabeledContent("Save as") {
                    HStack {
                        Text(file?.path ?? "No file chosen")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(file == nil ? .secondary : .primary)
                        Button("Choose…", action: chooseFile)
                    }
                }
            }
        } footer: {
            switch place {
            case .registry:
                Text("A registry, repository and tag. Sign in to private registries in Settings › Accounts.")
            case .file:
                Text("An image file (an OCI image layout in a tar) you can copy to another Mac yourself.")
            }
        }
    }
}

private struct PushedImageSection: View {
    let pushed: String
    let os: GuestOS
    let reference: String

    var body: some View {
        Section {
            LabeledContent("Pushed") {
                HStack {
                    Text(pushed).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Button("Copy") { Pasteboard.copy(pushed) }
                }
            }
        } footer: {
            Text(
                "Create VMs from it with New Virtual Machine › From an Image, or `hangar create <vm> --os \(os.rawValue) --image \(reference)`."
            )
        }
    }
}

private struct SavedFileSection: View {
    let file: URL
    let os: GuestOS

    var body: some View {
        Section {
            LabeledContent("Saved") {
                HStack {
                    Text(file.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Button("Copy") { Pasteboard.copy(file.path) }
                }
            }
        } footer: {
            Text(
                "Create VMs from it with New Virtual Machine › From an Image › Choose File…, or `hangar create <vm> --os \(os.rawValue) --image \(quotedPath)`."
            )
        }
    }

    /// Single quotes keep a path with spaces in one piece when the command is pasted into a shell.
    private var quotedPath: String {
        "'" + file.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private struct ExportButtons: View {
    let job: ExportJob
    let canExport: Bool
    let export: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack {
            Spacer()
            if job.isRunning {
                Button("Cancel", role: .cancel) { job.cancel() }
            } else {
                Button(job.exported == nil ? "Cancel" : "Done", role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction)
                if job.exported == nil {
                    Button("Export", action: export)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canExport)
                }
            }
        }
    }
}
