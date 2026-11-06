import Foundation
import HangarKit
import Observation

@MainActor
@Observable
final class ExportJob {
    enum Destination {
        case registry(ImageReference)
        /// `replacing` only when the save panel asked about a file that was there.
        case file(URL, replacing: Bool)
    }

    enum Exported {
        /// The image by digest, like registry/repo@sha256:….
        case pushed(String)
        case saved(URL)
    }

    var progress: String?
    var exported: Exported?
    var problem: String?
    private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    func start(_ target: ExportTarget, to destination: Destination) {
        let store = VMStore.shared
        guard store.beginBusy(target.vm, doing: "export \(target.vm)") else { return }
        progress = "Starting"
        exported = nil
        problem = nil
        task = Task {
            defer { store.endBusy(target.vm) }
            do {
                let bundle = try VMLibrary.bundle(named: target.vm)
                exported = try await export(bundle, snapshot: target.snapshot, to: destination)
            } catch is CancellationError {
                problem = "Cancelled."
            } catch {
                problem = error.localizedDescription
            }
            progress = nil
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func export(_ bundle: VMBundle, snapshot: VMSnapshot?, to destination: Destination) async throws -> Exported
    {
        switch destination {
        case .registry(let reference):
            let credentials = try RegistryCredentials.forRegistry(reference.registry)
            let digest = try await VMImage.push(
                bundle, snapshot: snapshot, to: [reference], credentials: credentials, report: showProgress)
            return .pushed("\(reference.registry)/\(reference.repository)@\(digest)")
        case .file(let file, let canReplace):
            _ = try await VMImage.export(
                bundle, snapshot: snapshot, to: file, replacing: canReplace, report: showProgress)
            return .saved(file)
        }
    }

    private var showProgress: @Sendable (String) -> Void {
        { line in
            Task { @MainActor in if self.isRunning { self.progress = line } }
        }
    }
}
