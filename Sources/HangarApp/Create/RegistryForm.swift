import HangarKit
import HangarSupport
import SwiftUI
import UniformTypeIdentifiers

struct RegistryForm: View {
    static let formHeight: CGFloat = 470

    @Environment(VMStore.self) private var store
    let close: () -> Void
    let created: (UUID) -> Void

    private struct Found {
        let pinned: String
        let config: VMImage.Config
    }

    @State private var name = ""
    @State private var image = ""
    @State private var found: Found?
    /// The image being looked up; SwiftUI cancels the look-up when it changes or the form closes.
    @State private var lookingUp: String?
    @State private var choosingFile = false
    @State private var lookUpProblem: String?
    @State private var cpus = 2
    @State private var memoryGB = 4
    @State private var diskGB = 20
    @State private var network = NetworkMode.managed
    @State private var account = AccountFields(createAccount: false)

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("vm"))
                }
                ImageLookUpSection(
                    image: $image, isLookingUp: lookingUp != nil, canLookUp: canLookUp, footer: imageFooter,
                    lookUp: { lookingUp = image }, cancel: { lookingUp = nil }, chooseFile: { choosingFile = true })
                if let os {
                    RegistryAccountSection(
                        os: os, imageAccount: imageAccount, takesNewAccount: takesNewAccount,
                        createAccount: $account.createAccount, username: $account.username,
                        password: $account.password)
                }
                ResourcesSection(cpus: $cpus, memoryGB: $memoryGB, diskGB: $diskGB, minimumDiskGB: minimumDiskGB)
                Section {
                    Picker("Network", selection: $network) {
                        ForEach(NetworkMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: Self.formHeight)
            Divider()
            CreateFormFooter(problem: validationMessage, createTitle: "Create", close: close, create: create)
        }
        .onAppear { if name.isEmpty { name = store.uniqueName("vm") } }
        .task(id: lookingUp) { await lookUp() }
        .onChange(of: image) { forgetLookUp() }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.tarArchive]) { result in
            guard case .success(let picked) = result else { return }
            image = picked.path
            // A chosen file is read at once; changing the image first forgets any earlier look-up.
            Task { @MainActor in lookingUp = image }
        }
    }

    private var imageFooter: String {
        if let lookUpProblem { return lookUpProblem }
        if let found {
            let account = found.config.account.map { ", with the account \($0)" } ?? ""
            return "\(found.config.title)\(account). Hangar uses \(found.pinned)."
        }
        return
            "An image saved with hangar export or Export…: a registry tag, an @sha256 digest or a .tar file. Look Up "
            + "reads only its settings; the disk comes when you create the VM. Sign in to private registries in "
            + "Settings › Accounts."
    }

    private var os: GuestOS? { found?.config.os }

    private var imageAccount: String? { found?.config.account }
    private var takesNewAccount: Bool { found?.config.takesNewAccount ?? false }

    private var imageDiskGB: Int {
        Int(((found?.config.diskSize ?? 0) + ByteSize.gib - 1) / ByteSize.gib)
    }

    private var minimumDiskGB: Int {
        max(Int((os ?? .linux).minimumDiskSize / ByteSize.gib), imageDiskGB)
    }

    private var canLookUp: Bool {
        VMImage.isImageFile(image) || (try? ImageReference(image)) != nil
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var validationMessage: String? {
        if let problem = store.nameProblem(trimmedName) { return problem }
        guard canLookUp else { return "Enter an image like ghcr.io/acme/ci-linux:1.0, or choose a .tar file." }
        guard let os else { return "Look up the image." }
        guard takesNewAccount else { return nil }
        do {
            if os == .linux { try account.linux?.validate() } else { try account.mac?.validate() }
        } catch {
            return error.localizedDescription
        }
        return nil
    }

    private func forgetLookUp() {
        lookingUp = nil
        found = nil
        lookUpProblem = nil
    }

    private func lookUp() async {
        guard let wanted = lookingUp else { return }
        lookUpProblem = nil
        do {
            let lookedUp = try await find(wanted)
            guard !Task.isCancelled else { return }
            found = lookedUp
            applyDefaults(for: lookedUp.config.os)
            diskGB = max(diskGB, imageDiskGB)
        } catch is CancellationError {
            return
        } catch {
            lookUpProblem = error.localizedDescription
        }
        lookingUp = nil
    }

    private func find(_ location: String) async throws -> Found {
        if VMImage.isImageFile(location) {
            let file = URL(userPath: location)
            return Found(pinned: file.path, config: try await VMImage.inspect(imageFile: file))
        }

        let reference = try ImageReference(location)
        let credentials = try RegistryCredentials.forRegistry(reference.registry)
        let (pinned, config) = try await VMImage.inspect(reference, credentials: credentials)
        return Found(pinned: pinned.description, config: config)
    }

    private func applyDefaults(for os: GuestOS) {
        cpus = os.defaultCPUCount
        memoryGB = Int(os.defaultMemorySize / ByteSize.gib)
        diskGB = Int(os.defaultDiskSize / ByteSize.gib)
    }

    private func create() {
        guard validationMessage == nil, let os else { return }
        let macAccount = takesNewAccount && os == .macOS ? account.mac : nil
        let linuxAccount = takesNewAccount && os == .linux ? account.linux : nil
        let options = CreateOptions(
            cpuCount: cpus, memorySize: UInt64(memoryGB) * ByteSize.gib, diskSize: UInt64(diskGB) * ByteSize.gib,
            network: network)
        let source = imageSource(os: os, macAccount: macAccount, linuxAccount: linuxAccount)
        created(store.create(name: trimmedName, source: source, options: options))
    }

    private func imageSource(os: GuestOS, macAccount: MacProvisioning?, linuxAccount: CloudInitAccount?) -> VMSource {
        let pinned = found?.pinned ?? image
        guard VMImage.isImageFile(pinned) else {
            return .registryImage(pinned, os: os, macAccount: macAccount, linuxAccount: linuxAccount)
        }
        return .imageFile(
            URL(userPath: pinned), os: os, macAccount: macAccount, linuxAccount: linuxAccount, userData: nil)
    }
}

private struct ImageLookUpSection: View {
    @Binding var image: String
    let isLookingUp: Bool
    let canLookUp: Bool
    let footer: String
    let lookUp: () -> Void
    let cancel: () -> Void
    let chooseFile: () -> Void

    var body: some View {
        Section {
            TextField("Image", text: $image, prompt: Text("ghcr.io/acme/ci-linux:1.0"))
            HStack {
                if isLookingUp {
                    ProgressView().controlSize(.small)
                    Button("Cancel", action: cancel)
                } else {
                    Button("Look Up", action: lookUp)
                        .disabled(!canLookUp)
                }
                Spacer()
                Button("Choose File…", action: chooseFile)
            }
        } header: {
            Text("Image")
        } footer: {
            Text(footer)
        }
    }
}

private struct RegistryAccountSection: View {
    let os: GuestOS
    let imageAccount: String?
    let takesNewAccount: Bool
    @Binding var createAccount: Bool
    @Binding var username: String
    @Binding var password: String

    var body: some View {
        if takesNewAccount {
            NewAccountSection(
                createAccount: $createAccount, username: $username, password: $password,
                footer: os == .linux
                    ? "Through cloud-init, if the image has it; the image's own accounts stay."
                    : "Skips Setup Assistant on macOS 27 and later.")
        } else {
            Section("Account") {
                LabeledContent("Account", value: imageAccount ?? "The image's own")
            }
        }
    }
}
