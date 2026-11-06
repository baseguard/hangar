import AppKit
import HangarKit
import HangarSupport
import SwiftUI
import UniformTypeIdentifiers

struct CreateForm: View {
    static let formHeight: CGFloat = 470

    @Environment(VMStore.self) private var store
    let kind: CreateVMView.Kind
    @Binding var choice: CreateVMView.Choice
    let close: () -> Void
    let created: (UUID) -> Void

    enum Location: String, CaseIterable {
        case file = "File"
        case url = "URL"
        case later = "Later"
    }

    @State private var name = ""
    @State private var location = Location.file
    @State private var path = ""
    @State private var url = ""
    @State private var cpus = GuestOS.linux.defaultCPUCount
    @State private var memoryGB = Int(GuestOS.linux.defaultMemorySize / ByteSize.gib)
    @State private var diskGB = Int(GuestOS.linux.defaultDiskSize / ByteSize.gib)
    @State private var network = NetworkMode.managed
    @State private var account = AccountFields()
    @State private var usesOwnCloudInit = false
    @State private var cloudInitText = ""
    @State private var choosingFile = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text(choice.baseName))
                    if kind.choices.count > 1 {
                        Picker("Start from", selection: $choice) {
                            ForEach(kind.choices) { Text($0.title).tag($0) }
                        }
                    }
                }
                SourceSection(choice: choice, location: $location, url: $url, path: path) { choosingFile = true }
                AccountSection(choice: choice, account: $account)
                if usesCloudInit { CloudInitSection(usesOwnCloudInit: $usesOwnCloudInit, text: $cloudInitText) }
                ResourcesSection(cpus: $cpus, memoryGB: $memoryGB, diskGB: $diskGB, minimumDiskGB: minimumDiskGB)
                NetworkChoiceSection(network: $network)
            }
            .formStyle(.grouped)
            .frame(height: Self.formHeight)
            Divider()
            CreateFormFooter(problem: validationMessage, createTitle: "Create", close: close, create: create)
        }
        .onAppear(perform: applyDefaults)
        .onChange(of: choice) { old, new in
            location = .file
            if name.isEmpty || name == store.uniqueName(old.baseName) { name = store.uniqueName(new.baseName) }
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: allowedTypes) { result in
            if case .success(let picked) = result { path = picked.path }
        }
    }

    private var usesCloudInit: Bool {
        choice == .debian || choice == .ubuntu || choice == .cloudImage
    }

    private var cloudInitUserData: String? {
        let text = cloudInitText.trimmingCharacters(in: .whitespacesAndNewlines)
        return usesOwnCloudInit && !text.isEmpty ? text + "\n" : nil
    }

    private var cloudInitAccount: CloudInitAccount? { account.linux }

    private var macAccount: MacProvisioning? { account.mac }

    private var minimumDiskGB: Int {
        Int((choice.kind.os ?? .linux).minimumDiskSize / ByteSize.gib)
    }

    private var allowedTypes: [UTType] {
        [UTType(filenameExtension: "iso") ?? .data, .diskImage]
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var validationMessage: String? {
        if let problem = store.nameProblem(trimmedName) { return problem }
        do {
            switch choice {
            case .macOS:
                try macAccount?.validate()
            case .ipsw:
                try macAccount?.validate()
            case .debian, .ubuntu, .cloudImage:
                if choice == .cloudImage, !isWebAddress(url) { return "Enter an https:// address." }
                try cloudInitAccount?.validate()
                try cloudInitUserData.map(CloudInit.validate(userData:))
            case .linuxISO:
                if location == .file, path.isEmpty { return "Choose an ISO." }
                if location == .url, !isWebAddress(url) { return "Enter an https:// address." }
            case .windows:
                if !WindowsPlatform.isSupported { return "This version of macOS can't run Windows." }
                if location == .url ? !isWebAddress(url) : path.isEmpty {
                    return "Choose the Windows ISO (https for a URL)."
                }
                try account.windows.validate(forVM: trimmedName)
            case .macOSHomebrew, .macOSXcode, .registry:
                break
            }
        } catch {
            return error.localizedDescription
        }
        return nil
    }

    private func isWebAddress(_ text: String) -> Bool {
        URL(string: text)?.scheme?.lowercased() == "https"
    }

    private func applyDefaults() {
        let os = choice.kind.os ?? .linux
        cpus = os.defaultCPUCount
        memoryGB = Int(os.defaultMemorySize / ByteSize.gib)
        diskGB = Int(os.defaultDiskSize / ByteSize.gib)
        if name.isEmpty { name = store.uniqueName(choice.baseName) }
    }

    private func create() {
        guard validationMessage == nil, let vmSource else { return }
        let options = CreateOptions(
            cpuCount: cpus, memorySize: UInt64(memoryGB) * ByteSize.gib,
            diskSize: UInt64(diskGB) * ByteSize.gib, network: network)
        created(store.create(name: trimmedName, source: vmSource, options: options))
    }

    private var vmSource: VMSource? {
        let file = location == .url ? url : path
        switch choice {
        case .macOS, .macOSHomebrew, .macOSXcode:
            return choice.macImage.map { .macImage($0, account: choice == .macOS ? macAccount : nil) }
        case .ipsw:
            return .macOS(ipsw: "latest", account: macAccount)
        case .debian, .ubuntu:
            return choice.linuxImage.map {
                .linuxCloudImage($0, account: cloudInitAccount, userData: cloudInitUserData)
            }
        case .linuxISO:
            return .linux(iso: location == .later ? nil : file, diskImage: nil, account: nil, userData: nil)
        case .cloudImage:
            return .linux(iso: nil, diskImage: url, account: cloudInitAccount, userData: cloudInitUserData)
        case .windows:
            return .windows(
                iso: file,
                account: account.windows)
        case .registry:
            return nil
        }
    }
}

private struct SourceSection: View {
    let choice: CreateVMView.Choice
    @Binding var location: CreateForm.Location
    @Binding var url: String
    let path: String
    let chooseFile: () -> Void

    var body: some View {
        switch choice {
        case .macOS, .macOSHomebrew, .macOSXcode:
            SourceSummarySection(
                title: "Image", value: "hangar-macos:\(choice.macImage ?? "")", summary: choice.summary)
        case .ipsw:
            SourceSummarySection(title: "Source", value: "Apple", summary: choice.summary)
        case .debian, .ubuntu:
            SourceSummarySection(title: "Source", value: choice.linuxImage?.source ?? "", summary: choice.summary)
        case .linuxISO:
            LinuxISOSourceSection(location: $location, url: $url, path: path, chooseFile: chooseFile)
        case .cloudImage:
            CloudImageSourceSection(url: $url)
        case .windows:
            WindowsSourceSection(location: $location, url: $url, path: path, chooseFile: chooseFile)
        case .registry:
            EmptyView()
        }
    }
}

private struct AccountSection: View {
    let choice: CreateVMView.Choice
    @Binding var account: AccountFields

    var body: some View {
        switch choice {
        case .macOS, .ipsw:
            MacAccountSection(
                createAccount: $account.createAccount, username: $account.username, fullName: $account.fullName,
                password: $account.password, autoLogin: $account.autoLogin, remoteLogin: $account.remoteLogin)
        case .macOSHomebrew, .macOSXcode:
            ImageAccountSection(
                footer:
                    "The image comes with this administrator, and SSH is on. Anyone who can reach the VM can sign in with this password, so change it in the VM."
            )
        case .debian, .ubuntu, .cloudImage:
            NewAccountSection(
                createAccount: $account.createAccount, username: $account.username, password: $account.password,
                footer:
                    "Cloud-init creates this account with administrator rights; only a hash of the password is kept. For SSH keys or other users, turn this off and set them up in the cloud-init field below."
            )
        case .windows:
            WindowsAccountSection(
                username: $account.username, password: $account.password, remoteDesktop: $account.remoteDesktop)
        case .linuxISO, .registry:
            EmptyView()
        }
    }
}

private struct SourceSummarySection: View {
    let title: LocalizedStringKey
    let value: String
    let summary: String

    var body: some View {
        Section {
            LabeledContent(title, value: value)
        } footer: {
            Text(summary)
        }
    }
}

private struct LinuxISOSourceSection: View {
    @Binding var location: CreateForm.Location
    @Binding var url: String
    let path: String
    let chooseFile: () -> Void

    var body: some View {
        Section {
            LocationPicker(title: "ISO", locations: CreateForm.Location.allCases, location: $location)
            switch location {
            case .file: FileRow(path: path, choose: chooseFile)
            case .url: TextField("URL", text: $url, prompt: Text("https://…/debian-13-arm64-netinst.iso"))
            case .later: EmptyView()
            }
        } footer: {
            Text(
                location == .later
                    ? "Attach an ISO later in the Virtual Machine menu."
                    : "Use an Arm64 (aarch64) ISO. Install from the VM's window, then detach the ISO.")
        }
    }
}

private struct CloudImageSourceSection: View {
    @Binding var url: String

    var body: some View {
        Section {
            TextField("URL", text: $url, prompt: Text("https://cloud.debian.org/…/debian-13-generic-arm64.raw"))
        } footer: {
            Text(
                "An Arm64 cloud image, raw or qcow2. It's downloaded once and grown to the disk size below."
            )
        }
    }
}

private struct WindowsSourceSection: View {
    @Binding var location: CreateForm.Location
    @Binding var url: String
    let path: String
    let chooseFile: () -> Void

    var body: some View {
        Section {
            LocationPicker(title: "Windows 11 Arm64 ISO", locations: [.file, .url], location: $location)
            if location == .url {
                TextField("URL", text: $url, prompt: Text("https://software.download.prss.microsoft.com/…arm64….iso"))
            } else {
                FileRow(path: path, choose: chooseFile)
            }
            if !WindowsPlatform.isSupported {
                Notice(
                    text: "This version of macOS can't run Windows.", systemImage: "exclamationmark.triangle.fill",
                    tint: .orange)
            }
        } footer: {
            HStack {
                Text("Get the Arm64 ISO from Microsoft.")
                Link(
                    "Download page",
                    destination: URL(constant: "https://www.microsoft.com/software-download/windows11arm64"))
            }
        }
    }
}

private struct LocationPicker: View {
    let title: String
    let locations: [CreateForm.Location]
    @Binding var location: CreateForm.Location

    var body: some View {
        Picker(title, selection: $location) {
            ForEach(locations, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }
}

private struct CloudInitSection: View {
    static let editorHeight: CGFloat = 120
    private static let example = "#cloud-config\npackages:\n  - git\nruncmd:\n  - echo hello"
    private static let textInset = NSTextContainer().lineFragmentPadding

    @Binding var usesOwnCloudInit: Bool
    @Binding var text: String

    var body: some View {
        Section {
            Toggle("Run my own cloud-init on the first start", isOn: $usesOwnCloudInit)
            if usesOwnCloudInit {
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .frame(height: Self.editorHeight)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(Self.example)
                                .font(.body.monospaced())
                                .foregroundStyle(.tertiary)
                                .padding(.leading, Self.textInset)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel("Cloud-init user data")
            }
        } header: {
            Text("Cloud-init")
        } footer: {
            Text(
                "A #cloud-config document or a #! script for the first start, e.g. packages to install. It's added to the account settings above."
            )
        }
    }
}
