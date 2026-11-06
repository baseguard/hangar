import Foundation
import HangarPackets

/// Where the inspector sends the guest's HTTPS to hosts that have a secret: the VM process's secrets proxy, on the
/// host's address in the VM network.
package struct SecretsDiversion: Sendable {
    package let endpoint: TCPRedirect.Endpoint
    package let connections: DivertedConnections

    package init(endpoint: TCPRedirect.Endpoint, connections: DivertedConnections) {
        self.endpoint = endpoint
        self.connections = connections
    }
}

/// Diverting the guest's HTTPS to hosts with a secret. The decision falls at the SYN, by the server's address and the
/// names DNS gave it; from then on every frame of the connection is moved to the proxy and back.
extension TrafficInspector {
    /// The hosts are lowercased once here; the names they are compared with come lowercased from every parser.
    package func useSecrets(for hosts: Set<String>, proxy: SecretsDiversion?) {
        secretHosts = Set(hosts.map { $0.lowercased() })
        secretsProxy = proxy
    }

    /// Watching a VM that has secrets is what lets its HTTPS reach the proxy, whatever the traffic mode.
    var tracksFlows: Bool { policy.watches || !secretHosts.isEmpty }

    func divertIfForSecretHost(_ flow: TrafficFlow, now: Date) {
        guard let secretsProxy, let guestIP, flow.verdict == .allowed, isForSecretHost(flow) else { return }
        let guest = TCPRedirect.Endpoint(address: guestIP, port: flow.key.guestPort)
        let destination = DivertedConnections.Destination(
            server: TCPRedirect.Endpoint(address: flow.key.remote, port: flow.key.remotePort), names: flow.names)
        flow.isDiverted = secretsProxy.connections.add(guest, to: destination, now: now)
        if flow.isDiverted { divertedFlows[flow.key.guestPort] = flow.key }
    }

    private func isForSecretHost(_ flow: TrafficFlow) -> Bool {
        flow.key.protocolNumber == Packet.protocolTCP && flow.key.remotePort == Packet.httpsPort
            && flow.names.contains { secretHosts.contains($0) }
    }

    func forgetDiversion(of flow: TrafficFlow) {
        // A guest that reused the port has a newer diversion there, which stays.
        guard flow.isDiverted, let secretsProxy, let guestIP, divertedFlows[flow.key.guestPort] == flow.key else {
            return
        }
        divertedFlows[flow.key.guestPort] = nil
        secretsProxy.connections.remove(TCPRedirect.Endpoint(address: guestIP, port: flow.key.guestPort))
    }

    /// The guest's frames as they go out: those of a diverted connection move to the proxy, and frames the guest
    /// addresses to the proxy itself are dropped, so it is reached only through a diversion.
    func redirectToProxy(_ frames: [[UInt8]]) -> [[UInt8]] {
        guard let secretsProxy else { return frames }
        return frames.compactMap { frame in
            guard let tcp = Self.tcpSegment(in: frame) else { return frame }
            let destination = TCPRedirect.Endpoint(address: tcp.ip.destination, port: tcp.destinationPort)
            if destination == secretsProxy.endpoint { return nil }
            let key = FlowKey(
                protocolNumber: Packet.protocolTCP, guestPort: tcp.sourcePort, remote: tcp.ip.destination,
                remotePort: tcp.destinationPort)
            guard flows[key]?.isDiverted == true else { return frame }
            return TCPRedirect.destination(of: tcp, frame: frame, to: secretsProxy.endpoint)
        }
    }

    /// The proxy's frame as if its server sent it; `nil` drops it. A frame from anywhere else comes back unchanged.
    func returnFromProxy(_ frame: [UInt8]) -> [UInt8]? {
        guard let secretsProxy, let tcp = Self.tcpSegment(in: frame) else { return frame }
        let source = TCPRedirect.Endpoint(address: tcp.ip.source, port: tcp.sourcePort)
        guard source == secretsProxy.endpoint else { return frame }

        guard let key = divertedFlows[tcp.destinationPort] else { return nil }
        let server = TCPRedirect.Endpoint(address: key.remote, port: key.remotePort)
        return TCPRedirect.source(of: tcp, frame: frame, to: server)
    }

    /// QUIC to a host with a secret is dropped, so its clients fall back to TCP, which the proxy sees.
    func isQUICToSecretHost(_ udp: UDPDatagram, now: Date) -> Bool {
        guard udp.destinationPort == Packet.httpsPort, !secretHosts.isEmpty else { return false }
        let names = knownNames(for: udp.ip.destination, now: now)?.names ?? []
        return names.contains { secretHosts.contains($0) }
    }

    /// HTTPS and SVCB records offer HTTP/3 and hide the server's name, so a host with a secret gets none.
    func asksForServiceRecord(of question: DNSMessage.Question) -> Bool {
        (question.type == DNSMessage.typeHTTPS || question.type == DNSMessage.typeSVCB)
            && secretHosts.contains(question.name)
    }

    private static func tcpSegment(in frame: [UInt8]) -> TCPSegment? {
        guard frame.count >= 14, Packet.readUInt16(frame, at: 12) == Packet.etherTypeIPv4,
            let ip = IPv4Packet(frame, offset: 14)
        else { return nil }
        return TCPSegment(ip)
    }
}
