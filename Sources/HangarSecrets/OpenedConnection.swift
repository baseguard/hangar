import Foundation
internal import HangarPackets
internal import HangarTraffic
internal import NIOCore
internal import NIOHTTP1
internal import NIOHTTP2
internal import NIOPosix
internal import NIOSSL
internal import NIOTLS

/// The HTTP version of an opened connection, as TLS names it (ALPN). The guest is offered only the one the server
/// chose, so its requests pass to the server one to one.
enum ApplicationProtocol: String {
    case http1 = "http/1.1"
    case http2 = "h2"
}

/// A diverted connection the proxy opens. The real server is reached and has proven its name first; only then does the
/// guest get its TLS answer, so no request can leave before the server is known to be the host.
enum OpenedConnection {
    static func open(
        guest: ChannelHandlerContext, reader: ClientHelloReader, serverName: String, guestOffersHTTP2: Bool,
        destination: DivertedConnections.Destination, state: SecretsProxyServer.State
    ) {
        let guestChannel = guest.channel
        guard let address = serverAddress(of: destination) else { return guestChannel.close(promise: nil) }

        let tls = state.toServerContext(guestOffersHTTP2: guestOffersHTTP2)
        let connected = connectToServer(at: address, as: serverName, on: guestChannel.eventLoop, tls: tls)
        connected.assumeIsolated().whenComplete { result in
            switch result {
            case .success((let server, .http1)):
                joinHTTP1(guest: guest, reader: reader, server: server, serverName: serverName, state: state)
            case .success((let server, .http2)):
                joinHTTP2(guest: guest, reader: reader, server: server, serverName: serverName, state: state)
            case .failure(let error):
                reportUnverified(serverName, error, state: state)
                guestChannel.close(promise: nil)
            }
        }
    }

    private static func serverAddress(of destination: DivertedConnections.Destination) -> SocketAddress? {
        try? SocketAddress(
            ipAddress: IPv4Address(destination.server.address).description, port: Int(destination.server.port))
    }

    /// The server's channel once its certificate checked out, with the HTTP version it chose; a server that fails
    /// its handshake is closed here.
    private static func connectToServer(
        at address: SocketAddress, as serverName: String, on eventLoop: any EventLoop, tls: NIOSSLContext
    ) -> EventLoopFuture<(any Channel, ApplicationProtocol)> {
        let handshake = eventLoop.makePromise(of: ApplicationProtocol.self)
        let connected = ClientBootstrap(group: eventLoop)
            .channelInitializer { server in
                server.eventLoop.makeCompletedFuture {
                    let operations = server.pipeline.syncOperations
                    try operations.addHandler(NIOSSLClientHandler(context: tls, serverHostname: serverName))
                    try operations.addHandler(HandshakeWatch(done: handshake))
                }
            }
            .connect(to: address)
        connected.whenFailure { handshake.fail($0) }

        return connected.flatMap { server in
            handshake.futureResult
                .map { (server, $0) }
                .flatMapErrorThrowing { error in
                    server.close(promise: nil)
                    throw error
                }
        }
    }

    /// The guest only sees its connection closed, so the traffic log says why.
    private static func reportUnverified(_ serverName: String, _ error: any Error, state: SecretsProxyServer.State) {
        let reason = "Hangar couldn't reach \(serverName) or check its certificate: \(error)"
        state.report(.secretsRefused(host: serverName, method: "", path: "", reason: reason, now: Date()))
    }

    /// The guest's side becomes TLS with this host's certificate, then HTTP/1.1 whose requests go to the server, one
    /// after another on the one connection.
    private static func joinHTTP1(
        guest: ChannelHandlerContext, reader: ClientHelloReader, server: any Channel, serverName: String,
        state: SecretsProxyServer.State
    ) {
        do {
            let context = try state.toGuestContext(for: serverName, speaking: .http1)
            let operations = guest.pipeline.syncOperations
            try operations.addHandler(NIOSSLServerHandler(context: context), position: .after(reader))
            try operations.configureHTTPServerPipeline(position: .last, withErrorHandling: true)
            try operations.addHandler(GuestRequests(server: server, serverName: serverName, state: state))
            try server.pipeline.syncOperations.addHTTPClientHandlers()
            try server.pipeline.syncOperations.addHandler(
                ServerResponses(guest: guest.channel, serverName: serverName, state: state))
        } catch {
            guest.channel.close(promise: nil)
            server.close(promise: nil)
            return
        }
        guest.fireChannelRead(NIOAny(reader.startPassing()))
    }

    /// The guest's side becomes TLS with this host's certificate, then HTTP/2. Each stream the guest opens gets a
    /// stream of its own to the server, and the two connections end together.
    private static func joinHTTP2(
        guest: ChannelHandlerContext, reader: ClientHelloReader, server: any Channel, serverName: String,
        state: SecretsProxyServer.State
    ) {
        do {
            let context = try state.toGuestContext(for: serverName, speaking: .http2)
            let serverOperations = server.pipeline.syncOperations
            let serverStreams = try serverOperations.configureHTTP2Pipeline(
                mode: .client, connectionConfiguration: withoutServerPush(), streamConfiguration: .init()
            ) { pushed in
                pushed.close()
            }
            try serverOperations.addHandler(ServerGoingAway(guest: guest.channel))

            let guestOperations = guest.pipeline.syncOperations
            try guestOperations.addHandler(NIOSSLServerHandler(context: context), position: .after(reader))
            _ = try guestOperations.configureHTTP2Pipeline(
                mode: .server, connectionConfiguration: guestStreamLimit(), streamConfiguration: .init()
            ) { guestStream in
                pair(guestStream, with: serverStreams, serverName: serverName, state: state)
            }
            try guestOperations.addHandler(GuestConnectionWatch(server: server))
        } catch {
            guest.channel.close(promise: nil)
            server.close(promise: nil)
            return
        }
        guest.fireChannelRead(NIOAny(reader.startPassing()))
    }

    /// Opens the server stream for a stream the guest opened. Both are read as HTTP/1-style parts, so the same
    /// `GuestRequests` and `ServerResponses` check and pass them as on an HTTP/1.1 connection.
    private static func pair(
        _ guestStream: any Channel, with serverStreams: NIOHTTP2Handler.StreamMultiplexer, serverName: String,
        state: SecretsProxyServer.State
    ) -> EventLoopFuture<Void> {
        serverStreams.createStreamChannel { serverStream in
            serverStream.eventLoop.makeCompletedFuture {
                let operations = serverStream.pipeline.syncOperations
                try operations.addHandler(HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https))
                try operations.addHandler(ServerResponses(guest: guestStream, serverName: serverName, state: state))
            }
        }
        .flatMapThrowing { serverStream in
            let operations = guestStream.pipeline.syncOperations
            try operations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec())
            try operations.addHandler(GuestRequests(server: serverStream, serverName: serverName, state: state))
        }
    }

    /// The proxy asks for what the guest asks for; a pushed response would reach the guest without a request.
    private static func withoutServerPush() -> NIOHTTP2Handler.ConnectionConfiguration {
        var configuration = NIOHTTP2Handler.ConnectionConfiguration()
        configuration.initialSettings.append(HTTP2Setting(parameter: .enablePush, value: 0))
        return configuration
    }

    /// Each stream the guest opens opens one at the server, with its buffers on both sides, so a guest connection gets
    /// 16 at a time, not NIO's 100: plenty for an API client, and a small bound on what one connection costs.
    private static func guestStreamLimit() -> NIOHTTP2Handler.ConnectionConfiguration {
        var configuration = NIOHTTP2Handler.ConnectionConfiguration()
        configuration.initialSettings.removeAll { $0.parameter == .maxConcurrentStreams }
        configuration.initialSettings.append(HTTP2Setting(parameter: .maxConcurrentStreams, value: 16))
        return configuration
    }
}

/// Completes with the HTTP version the server chose once its certificate checked out, or fails with why it didn't.
final class HandshakeWatch: ChannelInboundHandler {
    typealias InboundIn = NIOAny

    private let done: EventLoopPromise<ApplicationProtocol>

    init(done: EventLoopPromise<ApplicationProtocol>) {
        self.done = done
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted(let negotiated) = event {
            done.succeed(negotiated.flatMap(ApplicationProtocol.init(rawValue:)) ?? .http1)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        done.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        done.fail(ChannelError.ioOnClosedChannel)
        context.fireChannelInactive()
    }
}

/// Watches the guest's HTTP/2 connection. Its streams go to the server over the server's connection, so when this one
/// closes the server's closes too; and once the server has gone away (`ServerGoingAway`), this one closes as soon as
/// the guest's last stream has ended, as RFC 9113 § 6.8 asks, even for a guest that would keep it open.
final class GuestConnectionWatch: ChannelInboundHandler {
    typealias InboundIn = NIOAny
    typealias OutboundOut = HTTP2Frame

    /// Sent along the guest's connection when the server stops taking streams.
    struct ServerWentAway {}

    private let server: any Channel
    private var openStreams = 0
    private var serverWentAway = false
    private var isClosing = false

    init(server: any Channel) {
        self.server = server
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is NIOHTTP2StreamCreatedEvent: openStreams += 1
        case is StreamClosedEvent: openStreams -= 1
        case is ServerWentAway: serverWentAway = true
        default: break
        }
        context.fireUserInboundEventTriggered(event)
        if serverWentAway, openStreams == 0, !isClosing { closeAfterWhatWasSent(context: context) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        server.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }

    /// Closing drops what the guest hasn't read yet. A ping goes out after all of it, so once the ping is written,
    /// nothing is lost.
    private func closeAfterWhatWasSent(context: ChannelHandlerContext) {
        isClosing = true
        let ping = HTTP2Frame(streamID: .rootStream, payload: .ping(HTTP2PingData(), ack: false))
        context.writeAndFlush(wrapOutboundOut(ping)).assumeIsolated().whenComplete { _ in context.close(promise: nil) }
    }
}

/// Tells the guest, with a GOAWAY of its own, when the server stops taking streams on its HTTP/2 connection: the server
/// sent a GOAWAY, after a set number of requests or before it restarts, or closed the connection. The guest then opens
/// a new connection for its next requests instead of streams that would fail; the streams it has finish first, then
/// `GuestConnectionWatch` closes the connection.
final class ServerGoingAway: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame

    private let guest: any Channel
    private var hasToldGuest = false

    init(guest: any Channel) {
        self.guest = guest
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .goAway = unwrapInboundIn(data).payload { tellGuest() }
        context.fireChannelRead(data)
    }

    func channelInactive(context: ChannelHandlerContext) {
        tellGuest()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }

    /// The highest stream number lets every stream the guest opened so far finish (RFC 9113 § 6.8).
    private func tellGuest() {
        guard !hasToldGuest else { return }
        hasToldGuest = true
        let goAway = HTTP2Frame.FramePayload.goAway(lastStreamID: .maxID, errorCode: .noError, opaqueData: nil)
        guest.writeAndFlush(HTTP2Frame(streamID: .rootStream, payload: goAway), promise: nil)
        guest.pipeline.fireUserInboundEventTriggered(GuestConnectionWatch.ServerWentAway())
    }
}
