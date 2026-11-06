import ArgumentParser
import Foundation
import HangarKit
import HangarSupport

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Push a VM or one of its snapshots to a registry as an image, or save it to a file.",
        discussion: """
            Examples:
              hangar export deb ghcr.io/acme/ci-linux:1.0
                  Push the stopped VM deb.
              hangar export deb ghcr.io/acme/ci-linux:clean --snapshot clean
                  Push deb's snapshot clean; deb can keep running.
              hangar export deb ~/ci-linux.tar
                  Save deb as an image file (an OCI image layout in a tar).

            """ + VMImage.wholeDiskWarning + "\n\n" + VMImage.runningSnapshotWarning
                + " Start a new VM once before you push it, so its account is on the disk.\n\n"
                + "A target ending in .tar is a file; anything else is a registry. "
                + "Sign in to the registry first with `hangar login`."
    )

    @Argument(help: ArgumentHelp("The VM.", valueName: "vm")) var name: String
    @Argument(
        help: ArgumentHelp(
            "Where to push it, with a tag, or a .tar file to write.", valueName: "registry/repo:tag|file.tar"))
    var target: String
    @Option(help: ArgumentHelp("Push this snapshot instead of the VM's current disk.", valueName: "snapshot"))
    var snapshot: String?
    @Option(
        help: ArgumentHelp(
            "Upload in pieces of this many MB (5-512), for registries that limit request size; 0 sends each part whole.",
            valueName: "mb")) var chunkSize = 0
    @Flag(help: "Reach the registry over plain HTTP instead of HTTPS.") var insecure = false

    // Checked here rather than in run() so a mistake prints `hangar export`'s usage, not the root command's.
    func validate() throws {
        if VMImage.isImageFile(target) {
            try checkFileTarget()
        } else {
            try checkRegistryTarget()
        }
    }

    private func checkFileTarget() throws {
        guard chunkSize == 0, !insecure else {
            throw ValidationError("--chunk-size and --insecure go with a registry.")
        }
    }

    private func checkRegistryTarget() throws {
        let reference: ImageReference
        do {
            reference = try ImageReference(target, plainHTTP: insecure)
        } catch {
            throw ValidationError(error.localizedDescription)
        }
        guard reference.tag != nil, reference.digest == nil else {
            throw ValidationError("Give the place to push with a tag, like ghcr.io/acme/ci-linux:1.0.")
        }
    }

    func run() throws {
        let uploadChunkSize = try VMImage.uploadChunkSize(megabytes: chunkSize)
        let bundle = try VMLibrary.bundle(named: name)
        let selected = try snapshot.map { try bundle.snapshot(named: $0) }
        let os = try bundle.loadConfig().os
        if VMImage.isImageFile(target) {
            try saveFile(of: bundle, snapshot: selected, os: os)
        } else {
            try pushToRegistry(bundle, snapshot: selected, os: os, uploadChunkSize: uploadChunkSize)
        }
    }

    private func saveFile(of bundle: VMBundle, snapshot selected: VMSnapshot?, os: GuestOS) throws {
        let file = URL(userPath: target)
        runMain { [name] in
            let printer = ProgressPrinter()
            let digest = try await VMImage.export(bundle, snapshot: selected, to: file) {
                printer.update(CreationProgress(phase: "Saving \(name)", detail: $0))
            }
            printer.finish()
            print("Saved \(file.path) (\(digest)).")
            print("Create a VM from it with:")
            print("  hangar create <vm> --os \(os.rawValue) --image \(file.path)")
        }
    }

    private func pushToRegistry(
        _ bundle: VMBundle, snapshot selected: VMSnapshot?, os: GuestOS, uploadChunkSize: Int
    ) throws {
        let reference = try ImageReference(target, plainHTTP: insecure)
        if insecure { HangarLog.warning(ImageReference.plainHTTPWarning) }
        let credentials = try RegistryCredentials.forRegistry(reference.registry)
        runMain { [name] in
            let printer = ProgressPrinter()
            let digest = try await VMImage.push(
                bundle, snapshot: selected, to: [reference], credentials: credentials,
                uploadChunkSize: uploadChunkSize
            ) {
                printer.update(CreationProgress(phase: "Pushing \(name)", detail: $0))
            }
            printer.finish()
            print("Pushed \(reference) (\(digest)).")
            print("Create a VM from it with:")
            print("  hangar create <vm> --os \(os.rawValue) --image \(reference)")
        }
    }
}
