import AppKit
import HangarSupport

/// Finder's Share › Hangar. Only hands the shared files to the Hangar.app this extension is bundled in, which asks
/// for the VM; it reads no contents and keeps nothing.
final class ShareViewController: NSViewController {
    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        Task { await handOver() }
    }

    private func handOver() async {
        do {
            let files = try await sharedFiles()
            try await openInHangar(files)
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            extensionContext?.cancelRequest(withError: error)
        }
    }

    private func sharedFiles() async throws -> [URL] {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        let providers = items.flatMap { $0.attachments ?? [] }

        var files: [URL] = []
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            let url = try await Self.loadURL(from: provider)
            if url.isFileURL { files.append(url) }
        }
        return files
    }

    private static func loadURL(from provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                guard let url else {
                    return continuation.resume(
                        throwing: error ?? HangarError("Could not read one of the shared items."))
                }
                continuation.resume(returning: url)
            }
        }
    }

    private func openInHangar(_ files: [URL]) async throws {
        guard !files.isEmpty else { throw HangarError("Only files and folders on this Mac can be shared with Hangar.") }
        guard let hangar = AppExtensionBundle.containingApp(of: Bundle.main.bundleURL) else {
            throw HangarError("Hangar's Share extension works only inside Hangar.app; reinstall Hangar.")
        }
        try await NSWorkspace.shared.open(files, withApplicationAt: hangar, configuration: .init())
    }
}
