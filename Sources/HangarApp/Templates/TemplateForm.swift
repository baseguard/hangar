import HangarKit
import HangarSecrets
import HangarSupport
import SwiftUI
import UniformTypeIdentifiers

/// Makes a VM from a template, asking only what the template can't carry: a name, a file this Mac must have,
/// an account and the secret values.
struct TemplateForm: View {
    @Environment(VMStore.self) private var store
    let template: VMTemplate
    let templateName: String
    let close: () -> Void
    let created: (UUID) -> Void

    @State private var name = ""
    @State private var cpus = 2
    @State private var memoryGB = 4
    @State private var diskGB = 40
    @State private var network = NetworkMode.managed
    /// The file the template makes the VM from, when this Mac doesn't have it.
    @State private var missingFile: String?
    @State private var chosenFile: String?
    @State private var choosingFile = false
    @State private var sharedFolders: [SharedFolder] = []
    @State private var skippedFolders: [SkippedFolder] = []
    @State private var allowsWriteShares = false
    @State private var account = AccountFields()
    @State private var secretValues: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section { TextField("Name", text: $name) }
                TemplateOriginSection(
                    template: template, missingFile: missingFile, chosenFile: chosenFile,
                    skippedFolders: skippedFolders
                ) { choosingFile = true }
                if !sharedFolders.isEmpty || template.traffic != nil {
                    TemplateSharingSection(
                        template: template, sharedFolders: sharedFolders, allowsWriteShares: $allowsWriteShares)
                }
                if !template.shownSetupCommands.isEmpty || template.cloudInit != nil {
                    TemplateSetupSection(
                        commands: template.shownSetupCommands, cloudInitLines: template.shownCloudInitLines)
                }
                TemplateAccountSection(kind: accountKind, fields: $account)
                if let secrets = template.secrets, !secrets.isEmpty {
                    TemplateSecretsSection(secrets: secrets, values: $secretValues)
                }
                ResourcesSection(cpus: $cpus, memoryGB: $memoryGB, diskGB: $diskGB, minimumDiskGB: minimumDiskGB)
                NetworkChoiceSection(network: $network)
            }
            .formStyle(.grouped)
            .frame(height: CreateForm.formHeight)
            Divider()
            CreateFormFooter(problem: validationMessage, createTitle: "Create", close: close, create: create)
        }
        .onAppear(perform: applyTemplate)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.data]) { result in
            if case .success(let picked) = result { chosenFile = picked.path }
        }
    }

    private var origin: VMTemplate.Origin? {
        guard let from = template.from else { return nil }
        guard let chosenFile else { return from }
        return from.replacingLocalFile(with: chosenFile)
    }

    private var accountKind: TemplateAccountKind {
        TemplateAccountKind(template: template, origin: origin)
    }

    private var minimumDiskGB: Int {
        Int(template.os.minimumDiskSize / ByteSize.gib)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var validationMessage: String? {
        if let problem = store.nameProblem(trimmedName) { return problem }
        guard template.from != nil else { return "The template doesn't say what the VM is made from." }
        if let missingFile, chosenFile == nil {
            return "Choose \(URL(fileURLWithPath: missingFile).lastPathComponent)."
        }
        if template.os == .windows, !WindowsPlatform.isSupported { return "This version of macOS can't run Windows." }
        if hasWriteShares, !allowsWriteShares {
            return "Turn on “\(TemplateSharingSection.writeSharesTitle)” to create the VM."
        }
        if template.secrets?.isEmpty == false, network != .managed {
            return "Secrets need the \(NetworkMode.managed.displayName) network."
        }
        do {
            try validateAccount()
            for value in secretValues.values where !value.isEmpty { try SecretRule.validate(value: value) }
        } catch {
            return error.localizedDescription
        }
        return nil
    }

    /// Only the folders this form showed, so one that appears after it opened isn't shared unseen.
    private var templateAsShown: VMTemplate {
        var shown = template
        shown.sharedFolders = sharedFolders
        return shown
    }

    private var hasWriteShares: Bool {
        sharedFolders.contains { !$0.readOnly }
    }

    private func validateAccount() throws {
        switch accountKind {
        case .linux: try account.linux?.validate()
        case .mac: try account.mac?.validate()
        case .windows: try account.windows.validate(forVM: trimmedName)
        case .none, .hangarImage: break
        }
    }

    private func applyTemplate() {
        let os = template.os
        let hostMemoryGB = Int(ProcessInfo.processInfo.physicalMemory / ByteSize.gib)
        cpus = min(template.cpu ?? os.defaultCPUCount, ProcessInfo.processInfo.activeProcessorCount)
        memoryGB = min(template.memory ?? Int(os.defaultMemorySize / ByteSize.gib), hostMemoryGB)
        diskGB = max(template.disk ?? Int(os.defaultDiskSize / ByteSize.gib), minimumDiskGB)
        network = template.network ?? .managed
        name = store.uniqueName(VMLibrary.isValidName(templateName) ? templateName : os.rawValue)
        missingFile = template.from?.localFile.flatMap { FileManager.default.fileExists(atPath: $0) ? nil : $0 }
        let folders = template.sharedFoldersOnThisMac()
        sharedFolders = folders.shared
        skippedFolders = folders.skipped
    }

    private func create() {
        guard validationMessage == nil, let origin else { return }
        do {
            let kind = accountKind
            let source = try template.source(
                from: origin, linuxAccount: kind == .linux ? account.linux : nil,
                macAccount: kind == .mac ? account.mac : nil, windowsAccount: kind == .windows ? account.windows : nil)
            let options = CreateOptions(
                cpuCount: cpus, memorySize: UInt64(memoryGB) * ByteSize.gib,
                diskSize: UInt64(diskGB) * ByteSize.gib, network: network)
            let id = store.create(
                name: trimmedName, source: source, options: options, template: templateAsShown,
                secretValues: secretValues)
            created(id)
        } catch {
            store.report(error, doing: "make the VM")
        }
    }
}

private struct TemplateOriginSection: View {
    let template: VMTemplate
    let missingFile: String?
    let chosenFile: String?
    let skippedFolders: [SkippedFolder]
    let chooseFile: () -> Void

    var body: some View {
        Section {
            LabeledContent("System", value: template.os.displayName)
            LabeledContent("Made from") {
                Text(madeFrom).lineLimit(1).truncationMode(.middle)
            }
            if missingFile != nil {
                FileRow(path: chosenFile ?? "", choose: chooseFile)
            }
        } header: {
            Text("Template")
        } footer: {
            if !notes.isEmpty { Text(notes.joined(separator: " ")) }
        }
    }

    private var madeFrom: String {
        guard let from = template.from else { return "Not given" }
        if let cloudImage = from.cloudImage { return cloudImage.title }
        return from.image ?? from.diskImage ?? from.iso ?? from.ipsw ?? "Not given"
    }

    private var notes: [String] {
        var notes: [String] = []
        if let missingFile {
            notes.append("This Mac doesn't have \(missingFile); choose the file to use instead.")
        }
        for skipped in skippedFolders {
            notes.append(
                "The shared folder \(skipped.folder.name) is left out: \(VMTemplate.printable(skipped.reason))")
        }
        return notes
    }
}

/// The folders of this Mac the template shares and the traffic rules it sets; its author chose them, so a folder the
/// VM can change is shared only once the user turns that on.
private struct TemplateSharingSection: View {
    static let writeSharesTitle = "Share folders read-write"

    let template: VMTemplate
    let sharedFolders: [SharedFolder]
    @Binding var allowsWriteShares: Bool

    var body: some View {
        Section {
            ForEach(sharedFolders) { folder in
                LabeledContent {
                    Text(folder.readOnly ? "Read Only" : "Read & Write")
                } label: {
                    Text(VMTemplate.printable(folder.path)).textSelection(.enabled)
                    Text("Shared as \(folder.name)")
                }
            }
            if let traffic = template.trafficDescription {
                VStack(alignment: .leading) {
                    Text("Traffic")
                    Text(traffic).font(.callout).foregroundStyle(.secondary)
                }
            }
            if sharedFolders.contains(where: { !$0.readOnly }) {
                Toggle(isOn: $allowsWriteShares) {
                    Text(Self.writeSharesTitle)
                    Text("Programs in the VM can change and delete every file in the folders shared read-write.")
                }
            }
        } header: {
            Text("Folders and Traffic")
        }
    }
}

/// The template's commands as written, which Hangar's agent runs in the VM, and its cloud-init user data as written,
/// which cloud-init runs as root.
private struct TemplateSetupSection: View {
    let commands: [String]
    let cloudInitLines: [String]

    var body: some View {
        Section {
            ForEach(Array(commands.enumerated()), id: \.offset) { _, command in
                Text(command).monospaced().textSelection(.enabled)
            }
            if !cloudInitLines.isEmpty {
                CloudInitRow(lines: cloudInitLines)
            }
        } header: {
            Text("Setup Commands")
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        var sentences: [String] = []
        if !commands.isEmpty {
            sentences.append(
                "The first time Hangar's agent reports in from the VM, it runs these commands there; their output goes to setup.log in the VM's folder."
            )
        }
        if !cloudInitLines.isEmpty {
            sentences.append("Cloud-init runs the user data as root when the VM first starts.")
        }
        return sentences.joined(separator: " ")
    }
}

/// The user data can be up to 1 MB, so past a few lines it scrolls inside the row instead of stretching the form.
private struct CloudInitRow: View {
    private static let linesShownWhole = 10

    let lines: [String]

    var body: some View {
        VStack(alignment: .leading) {
            Text("Runs as root on its first start (cloud-init)")
            if lines.count > Self.linesShownWhole {
                ScrollView { UserDataText(lines: lines) }
                    .frame(height: Self.scrollHeight)
            } else {
                UserDataText(lines: lines)
            }
        }
    }

    private static var scrollHeight: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        return NSLayoutManager().defaultLineHeight(for: font) * CGFloat(linesShownWhole)
    }
}

private struct UserDataText: View {
    let lines: [String]

    var body: some View {
        Text(lines.joined(separator: "\n"))
            .monospaced()
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TemplateSecretsSection: View {
    let secrets: [VMTemplate.Secret]
    @Binding var values: [String: String]

    var body: some View {
        Section {
            ForEach(secrets, id: \.name) { secret in
                SecureField(text: value(of: secret.name), prompt: Text("Optional")) {
                    Text(secret.name)
                    Text("Sent only to \(secret.hosts.joined(separator: ", "))")
                }
            }
        } header: {
            Text("Secrets")
        } footer: {
            Text(
                "Each value goes to your Keychain only and is sent to its hosts in place of the variable the VM's programs see. Leave one empty to give it later in the VM's Secrets."
            )
        }
    }

    private func value(of name: String) -> Binding<String> {
        Binding(get: { values[name] ?? "" }, set: { values[name] = $0 })
    }
}
