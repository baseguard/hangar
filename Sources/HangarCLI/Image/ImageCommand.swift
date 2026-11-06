import ArgumentParser
import Foundation
import HangarKit
import HangarSupport

struct ImageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "image",
        abstract: "Build and push Hangar's macOS images; for maintainers.",
        shouldDisplay: false,
        subcommands: [Build.self, Prepare.self, FirstStart.self, Verify.self]
    )

    struct Build: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Build one of Hangar's macOS images in a VM named image-<kind>.",
            discussion: """
                vanilla installs the latest macOS and is never started. base starts from image-vanilla with the account \
                admin (password admin, Remote Login on) and installs the Command Line Tools, Homebrew and Hangar's agent; \
                xcode starts from image-base and adds Xcode. Preparing the first start runs `sudo hangar image prepare`.
                  hangar image build vanilla --push ghcr.io/baseguard/hangar-macos
                  hangar image build base --push ghcr.io/baseguard/hangar-macos
                  hangar image build xcode --xcode /Applications/Xcode.app --push ghcr.io/baseguard/hangar-macos
                """
        )

        @Argument(help: "vanilla, base or xcode.")
        var kind: ImageBuilder.Kind

        @Option(help: "The vanilla image's macOS: 'latest' from Apple, an IPSW path or https URL.")
        var ipsw = "latest"

        @Option(help: "The Xcode.app to install in the xcode image.")
        var xcode: String?

        @Option(help: "Push the image to this repository, tagged with its macOS (and Xcode) version.")
        var push: String?

        @Flag(help: "With --push: reach the registry over plain HTTP instead of HTTPS.")
        var insecure = false

        func validate() throws {
            guard (kind == .xcode) == (xcode != nil) else {
                throw ValidationError("--xcode goes with the xcode image, and it needs one.")
            }
            guard !insecure || push != nil else { throw ValidationError("--insecure goes with --push.") }
        }

        func run() throws {
            let xcodeVersion = try xcode.map(Self.xcodeVersion(of:))
            let repository = try push.map { try ImageReference("\($0):latest", plainHTTP: insecure) }
            if insecure { HangarLog.warning(ImageReference.plainHTTPWarning) }
            let credentials = try repository.flatMap { try RegistryCredentials.forRegistry($0.registry) }
            runMain { [self] in
                let printer = ProgressPrinter()
                let (bundle, macOS) = try await ImageBuilder.build(
                    kind, ipsw: ipsw, prepare: { try prepareWithSudo($0, xcode: xcode) }
                ) { printer.update($0) }
                printer.finish()
                if kind != .vanilla { try checkReadyToPush(bundle) }

                print("Built '\(bundle.name)' from macOS \(macOS.version) (\(macOS.build)).")
                guard let repository else { return }

                try await pushImage(
                    bundle, macOS: macOS, xcodeVersion: xcodeVersion, to: repository,
                    credentials: credentials)
            }
        }

        private static func xcodeVersion(of path: String) throws -> String {
            let info = Bundle(url: URL(fileURLWithPath: path))?.infoDictionary
            guard let version = info?["CFBundleShortVersionString"] as? String else {
                throw ValidationError("\(path) is not an Xcode.app.")
            }
            return version
        }

        private func checkReadyToPush(_ bundle: VMBundle) throws {
            try reportProblems(try ImageBuilder.verify(disk: bundle.diskURL), of: "'\(bundle.name)'")
        }

        @MainActor
        private func pushImage(
            _ bundle: VMBundle, macOS: ImageBuilder.MacOS, xcodeVersion: String?,
            to repository: ImageReference, credentials: RegistryCredentials?
        ) async throws {
            let tags = ImageBuilder.tags(kind: kind, macOS: macOS, xcode: xcodeVersion)
            let targets = try tags.map {
                try ImageReference(
                    "\(repository.registry)/\(repository.repository):\($0)", plainHTTP: repository.plainHTTP)
            }

            let details = try MacImage.details(of: bundle, build: macOS.build, xcode: xcodeVersion)
            let printer = ProgressPrinter()
            let digest = try await VMImage.push(bundle, to: targets, macOS: details, credentials: credentials) {
                printer.update(CreationProgress(phase: "Pushing \(bundle.name)", detail: $0))
            }
            printer.finish()
            print("Pushed \(targets.map(\.description).joined(separator: " and ")) (\(digest)).")
        }

        /// With sudo already unlocked in this terminal it runs there; otherwise the system asks for the password.
        private func prepareWithSudo(_ bundle: VMBundle, xcode: String?) throws {
            let command =
                [HangarExecutable.url.resolvingSymlinksInPath().path, "image", "prepare", bundle.diskURL.path]
                + (xcode.map { ["--xcode", $0] } ?? [])

            if (try? ProcessUtil.exitStatus(of: "/usr/bin/sudo", ["-n", "true"], quiet: true)) == 0 {
                try ProcessUtil.runShowingOutput("/usr/bin/sudo", ["-n"] + command)
            } else {
                let output = try ProcessUtil.runAsAdministrator(command)
                print(String(decoding: output, as: UTF8.self), terminator: "")
            }
        }
    }

    struct Prepare: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Put the one-time setup job into a macOS VM's disk; needs sudo.",
            discussion: "The job runs `hangar image first-start` as root on the VM's next start and deletes itself."
        )

        @Argument(help: "The VM's disk.img.")
        var disk: String

        @Option(help: "An Xcode.app to copy into /Applications.")
        var xcode: String?

        func run() throws {
            guard let app = HangarExecutable.appBundle else {
                throw ValidationError("Run `hangar image` from the command line inside Hangar.app.")
            }
            try ImageBuilder.prepare(
                disk: URL(fileURLWithPath: disk), app: app, xcode: xcode.map { URL(fileURLWithPath: $0) })
            print("Prepared \(disk).")
        }
    }

    struct Verify: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Check that a set-up VM's disk has nothing left over before it's pushed."
        )

        @Argument(help: "The VM's disk.img.")
        var disk: String

        func run() throws {
            try reportProblems(try ImageBuilder.verify(disk: URL(fileURLWithPath: disk)), of: disk)
            print("\(disk) is clean.")
        }
    }
}

/// Lists what is left over on an image's disk, one line each, and refuses the push.
private func reportProblems(_ problems: [String], of what: String) throws {
    guard !problems.isEmpty else { return }
    for problem in problems {
        printError("- \(problem)")
    }
    throw HangarError("\(what) isn't ready to push.")
}
