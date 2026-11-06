import Darwin
import Foundation
import HangarPackets
import HangarSecrets
import HangarSupport
import Observation
import Virtualization

/// What the control socket asks of a running session: `hangar exec` connections, and the requests the app and the
/// command line send.
extension VMSession {
    /// Connects the `hangar exec` caller on `client` to the guest agent: one connection to the guest per command, closed
    /// with the caller's.
    func startExec(_ request: ExecRequest, client: Int32) async {
        let guest: Int32
        let start: Data
        do {
            try checkCanExec()
            start = try ExecFrame(.start, payload: request.startPayload(fallbackUser: config.sshUser)).encoded
            guest = try await connectToExecPort()
        } catch {
            try? ControlSocket.writeMessage(ControlReply.failed(error.localizedDescription), to: client)
            close(client)
            return
        }

        guard (try? ControlSocket.writeMessage(ControlReply.done, to: client)) != nil else {
            close(client)
            close(guest)
            return
        }
        ExecBridge.relay(caller: client, guest: guest, start: start)
    }

    /// A descriptor of its own, so closing it never races Virtualization closing the connection's.
    private func connectToExecPort() async throws -> Int32 {
        guard let device = virtualMachine.socketDevices.first as? VZVirtioSocketDevice else {
            throw HangarError("'\(name)' has no socket device for hangar exec; shut it down and start it again.")
        }
        let connection: VZVirtioSocketConnection
        do {
            connection = try await device.connect(toPort: ExecBridge.port)
        } catch {
            throw HangarError("The agent in '\(name)' isn't taking commands yet; try again in a moment.")
        }
        defer { connection.close() }

        let fd = fcntl(connection.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else { throw HangarError(errno: errno, "Could not keep the connection to '\(name)'") }
        return fd
    }

    /// Decided before anything reaches the guest, so an old or missing agent is named instead of waited for.
    private func checkCanExec() throws {
        guard state == .running else {
            throw HangarError(state == .paused ? "'\(name)' is paused; resume it first." : "'\(name)' isn't running.")
        }
        guard let version = guestReport?.agentVersion else {
            throw HangarError(
                "'\(name)' has no agent answering yet. Wait until it has started, or install the agent: "
                    + "hangar setup \(name)")
        }
        guard version >= GuestSetup.firstExecAgentVersion else {
            throw HangarError(
                "'\(name)' has Hangar's agent \(version); hangar exec needs \(GuestSetup.firstExecAgentVersion) "
                    + "or later. Update it: hangar setup \(name)")
        }
    }

    /// What the control socket answers; the app asks a VM it runs here directly, without the socket.
    package func handleControl(_ request: ControlRequest) async -> ControlReply {
        do {
            switch request {
            case .status:
                return .state(MachineState(state))
            case .memory:
                return .report(guestReport)
            case .stop:
                try await requestStop()
            case .forceStop:
                try await forceStop()
            case .pause:
                try await pause()
            case .resume:
                try await resume()
            case .reloadTrafficRules:
                try reloadTrafficPolicy()
            case .reloadSecrets:
                try reloadSecrets()
            case .reloadSharedFolders:
                try reloadSharedFolders()
            case .takeSnapshot(let snapshotName):
                try await takeSnapshot(named: snapshotName)
            case .exec:
                // ControlServer hands exec connections to startExec instead.
                return .failed("Hangar can't run that request here.")
            }
            return .done
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
