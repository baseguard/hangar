import ArgumentParser
import Foundation
import HangarKit
import HangarSupport

struct Create: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create a macOS, Linux or Windows VM.",
        discussion: """
            Examples:
              hangar create mac --os macos --user dev
                  The latest macOS, with your account dev.
              hangar create mac --os macos --image xcode
                  macOS with Homebrew and Xcode (user admin, password admin).
              hangar create deb --os linux --image debian
                  Debian ready in seconds (user admin, password admin).
              hangar create deb --os linux --user dev \\
                --disk-image ~/Downloads/debian-13-generic-arm64.qcow2
                  Debian from a cloud image file, with your own account.
              hangar create deb --os linux --iso ~/Downloads/debian-13.iso
                  Debian from its installer: install it with `hangar run deb`.
              hangar create win --os windows --iso ~/Downloads/Win11.iso
                  Windows 11, installed by itself in a few minutes.
              hangar create ci --os linux --image ghcr.io/acme/ci:1.0
                  A VM from your team's image (see `hangar export`).
              hangar create ci --os linux --image ~/ci-linux.tar
                  The same from an image file.
              hangar create go --template go-dev.hangarvm
                  A VM from a template (see `hangar template save`); options given here override it.

            Hangar's macOS images: vanilla is plain macOS, base adds the Command Line \
            Tools and Homebrew, xcode adds Xcode. base and xcode sign in as admin, password admin.

            You're asked for the password, or give it on standard input with --password-stdin.

            A Linux VM made from an image gets new SSH host keys through cloud-init on its first start; an image \
            without cloud-init keeps the keys it has. For a private registry, sign in first with `hangar login`.
            """
    )

    @Argument(help: ArgumentHelp("The new VM's name.", valueName: "vm"))
    var name: String

    @OptionGroup(title: "Every VM")
    var machine: MachineOptions

    @OptionGroup(title: "Account")
    var account: AccountOptions

    @OptionGroup(title: "macOS")
    var mac: MacOptions

    @OptionGroup(title: "Linux")
    var linux: LinuxOptions

    @OptionGroup(title: "Linux and Windows")
    var installer: InstallerOptions

    @OptionGroup(title: "Windows")
    var windows: WindowsOptions

    struct MachineOptions: ParsableArguments {
        @Option(
            help: ArgumentHelp("A template to make the VM from; options given here override it.", valueName: "file"))
        var template: String?

        @Flag(help: "With --template: let it share folders of this Mac read-write.")
        var allowWriteShares = false

        @Option(help: ArgumentHelp("The system to install.", valueName: "macos|linux|windows"))
        var os: GuestOS?

        @Option(
            help: ArgumentHelp(
                "Default: 4 for macOS and Windows, 2 for Linux. The VM's processors.", valueName: "count"))
        var cpu: Int?

        @Option(
            help: ArgumentHelp("Default: 8 for macOS and Windows, 4 for Linux. The VM's memory in GB.", valueName: "gb")
        )
        var memory: Int?

        @Option(
            help: ArgumentHelp(
                "Default: 80 for macOS, 64 for Windows, 20 for Linux, or the disk image's size. Takes only the space it uses.",
                valueName: "gb"))
        var disk: Int?

        @Option(
            help: ArgumentHelp(
                "Default: managed, Hangar's network with traffic rules. nat: the system's NAT, without traffic rules. none: no network.",
                valueName: "managed|nat|none"))
        var network: NetworkMode?

        @Option(
            help: ArgumentHelp(
                "Default on macOS: vanilla. macOS: vanilla, base or xcode. Linux: debian or ubuntu. Any VM: an image in a registry (by tag or @sha256 digest) or a .tar file.",
                valueName: "name|registry/repo:tag|file.tar"))
        var image: String?

        @Flag(help: "With an image in a registry: reach the registry over plain HTTP instead of HTTPS.")
        var insecure = false
    }

    struct AccountOptions: ParsableArguments {
        @Option(
            help: ArgumentHelp(
                "Default on Windows: admin. The account to create; not with base, xcode or a Windows image.",
                valueName: "name"))
        var user: String?

        @Flag(help: "Read the account's password from standard input.")
        var passwordStdin = false
    }

    struct MacOptions: ParsableArguments {
        @Option(
            help: ArgumentHelp(
                "Install from an Apple restore image instead of an image: a file, an https URL or latest.",
                valueName: "file|url|latest"))
        var ipsw: String?

        @Flag(help: "Don't log in automatically.")
        var noAutoLogin = false

        @Flag(help: "Don't turn on Remote Login (SSH).")
        var noSsh = false
    }

    struct LinuxOptions: ParsableArguments {
        @Option(
            help: ArgumentHelp(
                "A cloud image or your own disk (raw or qcow2) to start from.",
                valueName: "file|url"))
        var diskImage: String?

        @Option(
            help: ArgumentHelp(
                "With --disk-image or --image: a #cloud-config file or a #! script that runs on the first start.",
                valueName: "file"))
        var cloudInit: String?

        @Option(
            help: ArgumentHelp(
                "With --user: a public key to sign in with, e.g. ~/.ssh/id_ed25519.pub.", valueName: "file"))
        var sshKey: String?
    }

    struct InstallerOptions: ParsableArguments {
        @Option(
            help: ArgumentHelp("An installer ISO. Windows: required, the Windows 11 Arm64 ISO.", valueName: "file|url"))
        var iso: String?
    }

    struct WindowsOptions: ParsableArguments {
        @Flag(help: "Don't turn on Remote Desktop.")
        var noRemoteDesktop = false
    }

    /// The options given, with a template's values where an option wasn't given.
    private struct Plan {
        var os: GuestOS
        var image: String?
        var cpu: Int?
        var memory: Int?
        var disk: Int?
        var network: NetworkMode?
        var ipsw: String?
        var iso: String?
        var diskImage: String?
        var cloudImage: LinuxCloudImage?
        /// The text of a cloud-init file.
        var cloudInit: String?
        var template: VMTemplate?

        /// Hangar's own Linux images count as a cloud image too.
        var isFromDisk: Bool { diskImage != nil || cloudImage != nil || exportedImage != nil }

        var exportedImage: String? {
            image.flatMap { $0.contains("/") || VMImage.isImageFile($0) ? $0 : nil }
        }
    }

    func validate() throws {
        try VMLibrary.validate(name: name)
        try check(try plan())
    }

    func run() throws {
        let plan = try plan()
        let options = try options(for: plan)
        let template = plan.template.map(disclose)
        // The password is asked here, before the async run starts, so Ctrl+C at its prompt stops the command as usual.
        let source = try source(for: plan)
        runMain { [self] in
            let printer = ProgressPrinter()
            let bundle = try await source.createVM(named: name, options: options) { printer.update($0) }
            printer.finish()
            if let template { try setUp(bundle, from: template) }
            print("Created '\(bundle.name)' with a \(ByteSize.format(bundle.diskSize)) disk.")
            print(nextStep(for: plan))
        }
    }

    private func plan() throws -> Plan {
        let givenCloudInit = try cloudInitText()
        var template = try machine.template.map { try VMTemplate.read(from: URL(userPath: $0)) }
        // --cloud-init replaces the template's user data, which then mustn't be shown as running in the VM.
        if givenCloudInit != nil { template?.cloudInit = nil }
        guard let os = machine.os ?? template?.os else { throw ValidationError("Give --os or --template.") }
        let givesOrigin = machine.image != nil || mac.ipsw != nil || installer.iso != nil || linux.diskImage != nil
        let origin = givesOrigin ? nil : template?.from
        let linuxImage = os == .linux ? machine.image.flatMap(LinuxCloudImage.init(rawValue:)) : nil
        if let file = origin?.localFile, !FileManager.default.fileExists(atPath: file) {
            throw ValidationError(
                "The template makes the VM from \(file), which this Mac doesn't have; give it with --iso, --ipsw, --disk-image or --image."
            )
        }

        return Plan(
            os: os, image: linuxImage == nil ? machine.image ?? origin?.image : nil, cpu: machine.cpu ?? template?.cpu,
            memory: machine.memory ?? template?.memory, disk: machine.disk ?? template?.disk,
            network: machine.network ?? template?.network, ipsw: mac.ipsw ?? origin?.ipsw,
            iso: installer.iso ?? origin?.iso, diskImage: linux.diskImage ?? origin?.diskImage,
            cloudImage: linuxImage ?? origin?.cloudImage, cloudInit: givenCloudInit ?? template?.cloudInit,
            template: template)
    }

    /// Shows what the template shares, the traffic rules it sets, the commands it runs and its cloud-init user data
    /// before anything is made. Returns it with only the folders shown, so one that appears while the VM is made
    /// isn't shared unseen.
    private func disclose(_ template: VMTemplate) -> VMTemplate {
        let folders = template.sharedFoldersOnThisMac()
        for folder in folders.skipped { printSkipped(folder) }
        let lines = template.disclosure(sharing: folders.shared)
        if !lines.isEmpty {
            print("The template gives the VM:")
            for line in lines { print("  \(line)") }
        }

        var shown = template
        shown.sharedFolders = folders.shared
        return shown
    }

    private func printSkipped(_ skipped: SkippedFolder) {
        printError("Skipped the shared folder \(skipped.folder.name): \(VMTemplate.printable(skipped.reason))")
    }

    /// The template's settings, traffic rules, secrets and setup steps; secrets get their values afterwards.
    private func setUp(_ bundle: VMBundle, from template: VMTemplate) throws {
        let skipped = try template.setUp(bundle, secretValues: [:])
        for folder in skipped { printSkipped(folder) }
        for secret in template.secrets ?? [] {
            let hosts = secret.hosts.joined(separator: ", ")
            print(
                "Give \(secret.name) its value, which Hangar sends to \(hosts) only: "
                    + "hangar secret set \(bundle.name) \(secret.name) --value-stdin")
        }
    }

    private func check(_ plan: Plan) throws {
        try checkResources(plan)
        try checkCloudImageOptions(plan)
        try checkGuestOnlyFlags(plan)
        try checkImageOptions(plan)
        try checkInstallerMedia(plan)
        try checkAccount(plan)
        try checkTemplateWriteShares(plan)
    }

    /// The template's author chose the folders, so one the VM can change is shared only when the user says so.
    private func checkTemplateWriteShares(_ plan: Plan) throws {
        if plan.template == nil, machine.allowWriteShares {
            throw ValidationError("--allow-write-shares goes with --template.")
        }
        let shared = plan.template?.sharedFoldersOnThisMac().shared ?? []
        let writable = shared.filter { !$0.readOnly }
        guard !writable.isEmpty, !machine.allowWriteShares else { return }

        let paths = writable.map { VMTemplate.printable($0.path) }.joined(separator: ", ")
        throw ValidationError(
            "The template shares \(paths) read-write, so the VM can change and delete files there. Give --allow-write-shares if you trust it."
        )
    }

    private func checkCloudImageOptions(_ plan: Plan) throws {
        let os = plan.os
        let fromDisk = plan.isFromDisk
        if os == .linux, !fromDisk, account.user != nil || account.passwordStdin {
            throw ValidationError(
                "On Linux, --user and --password-stdin go with a cloud image (--disk-image) or --image.")
        }
        if linux.sshKey != nil, os != .linux || account.user == nil {
            throw ValidationError("--ssh-key goes with --user on a Linux cloud image or --image.")
        }
        if plan.cloudInit != nil, os != .linux || !fromDisk {
            throw ValidationError("--cloud-init goes with a Linux cloud image (--disk-image) or --image.")
        }
    }

    private func checkGuestOnlyFlags(_ plan: Plan) throws {
        let os = plan.os
        if os != .windows, windows.noRemoteDesktop {
            throw ValidationError("--no-remote-desktop is for Windows guests.")
        }
        if os != .macOS, mac.noAutoLogin || mac.noSsh || plan.ipsw != nil {
            throw ValidationError("--ipsw, --no-auto-login and --no-ssh are for macOS guests.")
        }
    }

    private func checkImageOptions(_ plan: Plan) throws {
        if let image = plan.image, plan.exportedImage == nil, plan.os != .macOS {
            let linuxImages = LinuxCloudImage.allCases.map(\.rawValue).joined(separator: " and ")
            let ownImages =
                plan.os == .linux
                ? "Hangar's own Linux images are \(linuxImages)." : "Hangar has no Windows images of its own."
            throw ValidationError("--image \(image) isn't an image in a registry or a .tar file; \(ownImages)")
        }

        if machine.insecure, plan.exportedImage.map(VMImage.isImageFile) ?? true {
            throw ValidationError("--insecure goes with an image in a registry.")
        }

        if plan.image != nil, plan.ipsw != nil || plan.iso != nil || plan.diskImage != nil {
            throw ValidationError("Give --image, or --ipsw, --iso or --disk-image; not both.")
        }

        if let image = plan.image, plan.exportedImage == nil, image != "vanilla",
            account.user != nil || mac.noAutoLogin || mac.noSsh
        {
            throw ValidationError(
                "The \(image) image comes with its own account (admin); --user goes with the vanilla image or --ipsw.")
        }
    }

    private func checkInstallerMedia(_ plan: Plan) throws {
        let os = plan.os
        if os == .macOS, plan.iso != nil {
            throw ValidationError("--iso is for Linux and Windows guests.")
        }
        if os != .linux, plan.diskImage != nil {
            throw ValidationError("--disk-image is for Linux guests.")
        }
    }

    private func checkAccount(_ plan: Plan) throws {
        let interactive = isatty(STDIN_FILENO) != 0

        if plan.os == .windows, plan.exportedImage != nil {
            guard account.user == nil, !account.passwordStdin, !windows.noRemoteDesktop else {
                throw ValidationError(
                    "A Windows image comes with its own accounts; --user, --password-stdin and --no-remote-desktop go with --iso."
                )
            }
        } else if plan.os == .windows {
            guard plan.iso != nil else {
                throw ValidationError(Self.windowsNeedsISO)
            }
            guard account.passwordStdin || interactive else {
                throw ValidationError(
                    "Windows needs a password for its administrator account: run interactively to be asked, or pass --password-stdin."
                )
            }
        } else if account.user == nil, account.passwordStdin {
            throw ValidationError("--password-stdin goes with --user.")
        } else if account.user != nil, !account.passwordStdin, !interactive {
            throw ValidationError("--user needs a password: run interactively to be asked, or pass --password-stdin.")
        }
    }

    private func checkResources(_ plan: Plan) throws {
        let options = try options(for: plan)
        try validateResources(cpu: options.cpuCount, memory: options.memorySize)
        guard options.diskSize >= plan.os.minimumDiskSize else {
            throw ValidationError(
                "--disk must be at least \(plan.os.minimumDiskSize / ByteSize.gib) GB for \(plan.os.displayName).")
        }
    }

    private func options(for plan: Plan) throws -> CreateOptions {
        let memoryBytes = try plan.memory.map { try parseGigabytes($0, name: "--memory") }
        let diskSize = try plan.disk.map { try parseGigabytes($0, name: "--disk") } ?? plan.os.defaultDiskSize
        return CreateOptions(
            cpuCount: plan.cpu, memorySize: memoryBytes, diskSize: diskSize, network: plan.network ?? .managed)
    }

    private static let windowsNeedsISO = "Windows needs --iso (a Windows 11 Arm64 ISO) or --image."

    /// The same recipe the app follows; the accounts are asked for only where the VM gets one.
    private func source(for plan: Plan) throws -> VMSource {
        let origin = VMTemplate.Origin(
            image: plan.image, cloudImage: plan.cloudImage, diskImage: plan.diskImage, iso: plan.iso, ipsw: plan.ipsw)
        if machine.insecure { HangarLog.warning(ImageReference.plainHTTPWarning) }
        return try VMTemplate(os: plan.os, cloudInit: plan.cloudInit).source(
            from: origin, linuxAccount: plan.os == .linux ? try linuxCloudAccount() : nil,
            macAccount: plan.os == .macOS ? try macProvisioning() : nil,
            windowsAccount: plan.os == .windows && plan.exportedImage == nil ? try windowsAccount() : nil,
            plainHTTP: machine.insecure)
    }

    private func windowsAccount() throws -> WindowsInstaller.Account {
        let user = account.user ?? VMConfig.defaultUser
        let windowsAccount = WindowsInstaller.Account(
            username: user, password: try accountPassword(for: user), remoteDesktop: !windows.noRemoteDesktop)
        try windowsAccount.validate(forVM: name)
        return windowsAccount
    }

    private func cloudInitText() throws -> String? {
        guard let cloudInit = linux.cloudInit else { return nil }
        let url = URL(userPath: cloudInit)
        let text = try readText(of: url, called: "the cloud-init file")
        try CloudInit.validate(userData: text)
        return text
    }

    private func publicKey() throws -> String? {
        guard let sshKey = linux.sshKey else { return nil }
        let url = URL(userPath: sshKey)
        let text = try readText(of: url, called: "the SSH key")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readText(of url: URL, called what: String) throws -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw HangarError("Could not read \(what) \(url.path): \(error.localizedDescription)")
        }
    }

    private func accountPassword(for user: String) throws -> String {
        try VMConfig.validate(userName: user)
        if account.passwordStdin { return try requireNonEmpty(readSecretFromStandardInput()) }
        guard let password = askHidden("Password for \(user): "), let again = askHidden("Again: ") else {
            throw HangarError("Could not read the password.")
        }

        guard password == again else { throw HangarError("The passwords don't match.") }
        return try requireNonEmpty(password)
    }

    private func requireNonEmpty(_ password: String) throws -> String {
        guard !password.isEmpty else { throw HangarError("The password can't be empty.") }
        return password
    }

    private func macProvisioning() throws -> MacProvisioning? {
        let provisioning = try account.user.map { user in
            MacProvisioning(
                fullName: user, username: user, password: try accountPassword(for: user),
                autoLogin: !mac.noAutoLogin, remoteLogin: !mac.noSsh)
        }
        try provisioning?.validate()
        return provisioning
    }

    private func linuxCloudAccount() throws -> CloudInitAccount? {
        let cloudAccount = try account.user.map { user in
            CloudInitAccount(username: user, password: try accountPassword(for: user), sshKey: try publicKey())
        }
        try cloudAccount?.validate()
        return cloudAccount
    }

    private func nextStep(for plan: Plan) -> String {
        switch plan.os {
        case .linux where plan.iso != nil:
            "Run `hangar run \(name)` to install, then `hangar set \(name) --no-iso`."
        case .linux where plan.cloudInit != nil && account.user == nil:
            "Run it with `hangar run \(name)`. Hangar didn't set up an account; sign in with the one your cloud-init file creates."
        case .windows where plan.iso != nil:
            "Run it with `hangar run \(name)`. On its first start Windows finishes setting itself up and signs in."
        default: "Run it with `hangar run \(name)`."
        }
    }
}
