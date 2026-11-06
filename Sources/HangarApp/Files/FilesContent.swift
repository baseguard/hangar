import HangarKit
import SwiftUI

/// Whether a VM's files can be listed now, and if not, what the user can do about it.
enum FilesAvailability: Equatable {
    case notRunning
    /// Paused, starting or stopping: the agent can't answer until it runs again.
    case notReady(VMPhase)
    case agentNeeded(installed: Int?)
    case ready

    init(_ vm: VMItem?, agentVersion: Int?) {
        guard let vm, vm.isRunning else {
            self = .notRunning
            return
        }
        guard vm.phase == .running else {
            self = .notReady(vm.phase)
            return
        }
        guard let agentVersion, agentVersion >= GuestSetup.firstBrowseAgentVersion else {
            self = .agentNeeded(installed: agentVersion)
            return
        }
        self = .ready
    }
}

/// The folder's table, or why there is none.
struct FilesContent: View {
    let browser: FilesBrowser
    let availability: FilesAvailability

    var body: some View {
        switch availability {
        case .notRunning:
            ContentUnavailableView {
                Label("“\(browser.name)” Isn't Running", systemImage: "power")
            } description: {
                Text("Start it to browse its files.")
            }
        case .notReady(let phase):
            ContentUnavailableView {
                Label(
                    "“\(browser.name)” Is \(phase.title)", systemImage: phase == .paused ? "pause.circle" : "hourglass")
            } description: {
                Text("Its files can be browsed while it runs.")
            }
        case .agentNeeded(let installed):
            AgentNeededView(name: browser.name, installed: installed)
        case .ready:
            FolderView(browser: browser)
        }
    }
}

private struct FolderView: View {
    let browser: FilesBrowser

    var body: some View {
        if let folder = browser.folder {
            FileTable(browser: browser, folder: folder)
        } else if let error = browser.listingError {
            ContentUnavailableView {
                Label("Couldn't Open the Folder", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { browser.reload() }
            }
        } else {
            ProgressView()
        }
    }
}

/// Browsing runs the agent's `ls`, which older agents don't have.
private struct AgentNeededView: View {
    @Environment(VMStore.self) private var store
    let name: String
    let installed: Int?

    var body: some View {
        ContentUnavailableView {
            Label(
                installed == nil ? "Hangar's Agent Isn't Answering" : "Hangar's Agent Needs an Update",
                systemImage: "puzzlepiece.extension")
        } description: {
            Text(description)
        } actions: {
            if let update = store.agentUpdates[name] {
                AgentUpdateProgress(status: update.status(vm: name))
                Button("Cancel") { store.cancelAgentUpdate(of: name) }
                    .disabled(!update.canCancel)
            } else {
                Button(installed == nil ? "Install Guest Agent…" : "Update Guest Agent…", action: installOrUpdate)
            }
        }
    }

    /// An agent that answers is updated over `hangar exec`; any other is installed by hand.
    private func installOrUpdate() {
        if GuestAgentUpdate.canUpdate(from: installed) {
            store.updateAgent(name)
        } else {
            store.shareTools(with: name)
        }
    }

    private var description: String {
        let needed = GuestSetup.firstBrowseAgentVersion
        guard let installed else {
            return
                "Browsing files needs Hangar's agent \(needed) or later in “\(name)”. Install it, or wait if “\(name)” is still starting."
        }
        return "“\(name)” has Hangar's agent \(installed); browsing files needs \(needed) or later."
    }
}

private struct AgentUpdateProgress: View {
    let status: String

    var body: some View {
        HStack(spacing: Metrics.spacing) {
            ProgressView()
                .controlSize(.small)
            Text(status)
                .foregroundStyle(.secondary)
        }
    }
}
