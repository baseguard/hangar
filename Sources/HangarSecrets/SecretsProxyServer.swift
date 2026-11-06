import Foundation
package import HangarPackets
internal import HangarSupport
package import HangarTraffic
internal import NIOCore
internal import NIOPosix
internal import NIOSSL
import Synchronization

/// The VM process's secrets proxy. The inspector sends it the guest's HTTPS connections to hosts with a secret; it
/// opens those whose server name has a secret, puts the secrets in, and passes every other one through unopened.
package final class SecretsProxyServer: Sendable {
    /// What the proxy works with; replaced as a whole when the VM's secrets change.
    package struct Secrets: Sendable {
        package let rules: [SecretRule]
        let values: [String: String]
        let authority: SecretAuthority

        package init(rules: [SecretRule], values: [String: String], authority: SecretAuthority) {
            self.rules = rules
            self.values = values
            self.authority = authority
        }

        func hasSecret(for host: String) -> Bool {
            rules.contains { $0.applies(to: host) }
        }
    }

    package let endpoint: TCPRedirect.Endpoint
    private let channel: any Channel
    private let state: State

    /// Listens on the host's address in the VM network, never on every address.
    package static func start(
        on address: IPv4Address, connections: DivertedConnections, secrets: Secrets,
        report: @escaping @Sendable (TrafficEvent) -> Void
    ) throws -> SecretsProxyServer {
        let state = try State(secrets: secrets, connections: connections, report: report)
        let channel = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.backlog, value: 64)
            .childChannelOption(.allowRemoteHalfClosure, value: false)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try state.accept(channel) }
            }
            .bind(host: address.description, port: 0)
            .wait()
        guard let portNumber = channel.localAddress?.port, let port = UInt16(exactly: portNumber) else {
            channel.close(promise: nil)
            throw HangarError("The secrets proxy got no port to listen on.")
        }
        return SecretsProxyServer(
            endpoint: TCPRedirect.Endpoint(address: address.value, port: port), channel: channel, state: state)
    }

    private init(endpoint: TCPRedirect.Endpoint, channel: any Channel, state: State) {
        self.endpoint = endpoint
        self.channel = channel
        self.state = state
    }

    package func update(_ secrets: Secrets) {
        state.update(secrets)
    }

    package func stop() {
        channel.close(promise: nil)
    }

    /// A connection nobody diverted, so the proxy's initializer closes it.
    struct NotDiverted: Error {}
}

extension SecretsProxyServer {
    /// Shared by every connection's handlers, on any of the event loop's threads.
    final class State: Sendable {
        private struct ToGuestContextKey: Hashable {
            let host: String
            let applicationProtocol: ApplicationProtocol
        }

        let connections: DivertedConnections
        let report: @Sendable (TrafficEvent) -> Void
        /// TLS towards the real servers, with and without HTTP/2 offered.
        private let toServerHTTP1: NIOSSLContext
        private let toServerHTTP2: NIOSSLContext
        private let current: Mutex<Secrets>
        /// TLS towards the guest, per host it asked for.
        private let toGuestContexts = Mutex<[ToGuestContextKey: (context: NIOSSLContext, madeAt: Date)]>([:])

        init(
            secrets: Secrets, connections: DivertedConnections, report: @escaping @Sendable (TrafficEvent) -> Void
        ) throws {
            current = Mutex(secrets)
            self.connections = connections
            self.report = report
            toServerHTTP1 = try NIOSSLContext(configuration: Self.toServerConfiguration(offering: [.http1]))
            toServerHTTP2 = try NIOSSLContext(configuration: Self.toServerConfiguration(offering: [.http2, .http1]))
        }

        /// HTTP/2 is offered to the server only for a guest that offered it, since the guest gets what the server chose.
        func toServerContext(guestOffersHTTP2: Bool) -> NIOSSLContext {
            guestOffersHTTP2 ? toServerHTTP2 : toServerHTTP1
        }

        var secrets: Secrets { current.withLock { $0 } }

        func update(_ secrets: Secrets) {
            current.withLock { $0 = secrets }
            toGuestContexts.withLock { $0 = [:] }
        }

        /// Only a connection the inspector diverted is served; it is taken once, so it can't be reused.
        func accept(_ channel: any Channel) throws {
            guard let remote = channel.remoteAddress, let address = remote.ipAddress.flatMap(IPv4Address.init),
                let port = remote.port.flatMap(UInt16.init(exactly:)),
                let destination = connections.take(TCPRedirect.Endpoint(address: address.value, port: port))
            else {
                channel.close(promise: nil)
                throw NotDiverted()
            }
            try channel.pipeline.syncOperations.addHandler(ClientHelloReader(destination: destination, state: self))
        }

        /// The certificate the guest sees for `host`, made again once a day, well before it expires, so a VM that
        /// runs for weeks never shows an expired one.
        func toGuestContext(
            for host: String, speaking applicationProtocol: ApplicationProtocol, now: Date = Date()
        ) throws -> NIOSSLContext {
            let key = ToGuestContextKey(host: host, applicationProtocol: applicationProtocol)
            if let cached = toGuestContexts.withLock({ $0[key] }),
                SecretAuthority.isFresh(madeAt: cached.madeAt, now: now)
            {
                return cached.context
            }

            let context = try secrets.authority.toGuestContext(for: host, speaking: applicationProtocol, now: now)
            toGuestContexts.withLock { $0[key] = (context, now) }
            return context
        }

        /// The real server must prove it is the host, to the Mac's own trust roots, before a secret goes near it: the
        /// guest chooses the address, and maybe the DNS answer that named it.
        private static func toServerConfiguration(offering protocols: [ApplicationProtocol]) -> TLSConfiguration {
            var configuration = TLSConfiguration.makeClientConfiguration()
            configuration.certificateVerification = .fullVerification
            configuration.trustRoots = .default
            configuration.minimumTLSVersion = .tlsv12
            configuration.applicationProtocols = protocols.map(\.rawValue)
            return configuration
        }
    }
}
