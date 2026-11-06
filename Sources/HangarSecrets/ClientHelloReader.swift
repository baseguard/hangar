internal import HangarPackets
internal import HangarTraffic
internal import NIOCore
internal import NIOPosix

/// The first handler of a diverted connection. It reads the guest's TLS ClientHello for the server name, then either
/// opens the connection (the name has a secret, and DNS gave it to this address) or passes it through unopened, as a
/// host sharing the address (a CDN) needs. Until the next handlers are ready it keeps what the guest sends; after
/// that it passes everything on.
final class ClientHelloReader: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private enum Stage {
        case reading
        case connecting
        case passing
    }

    static let maximumWaiting = 1 << 20
    /// A guest that opens a connection and never sends its ClientHello would otherwise hold it for good.
    static let helloTimeout = TimeAmount.seconds(30)

    private let destination: DivertedConnections.Destination
    private let state: SecretsProxyServer.State
    private var stage = Stage.reading
    private var received = ByteBuffer()
    private var helloDeadline: Scheduled<Void>?

    init(destination: DivertedConnections.Destination, state: SecretsProxyServer.State) {
        self.destination = destination
        self.state = state
    }

    func handlerAdded(context: ChannelHandlerContext) {
        helloDeadline = context.eventLoop.assumeIsolated().scheduleTask(in: Self.helloTimeout) { [self] in
            if stage == .reading { context.close(promise: nil) }
        }
    }

    /// Also when the channel closes, which removes every handler.
    func handlerRemoved(context: ChannelHandlerContext) {
        helloDeadline?.cancel()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard stage != .passing else { return context.fireChannelRead(data) }
        var bytes = unwrapInboundIn(data)
        received.writeBuffer(&bytes)
        // A guest that keeps sending while the server is reached gets cut off rather than held in memory.
        guard received.readableBytes <= Self.maximumWaiting else { return context.close(promise: nil) }
        if stage == .reading { readHello(context: context) }
    }

    /// What the guest sent so far, for the handlers that take over; from now on its bytes pass straight on.
    func startPassing() -> ByteBuffer {
        stage = .passing
        defer { received = ByteBuffer() }
        return received
    }

    private func readHello(context: ChannelHandlerContext) {
        let bytes = Array(received.readableBytesView)
        switch HostSniffer.sniff(bytes) {
        case .needMore where bytes.count < HostSniffer.limit:
            return
        case .tls(let serverName?) where opens(serverName):
            stage = .connecting
            OpenedConnection.open(
                guest: context, reader: self, serverName: serverName,
                guestOffersHTTP2: HostSniffer.offeredProtocols(bytes).contains(ApplicationProtocol.http2.rawValue),
                destination: destination, state: state)
        default:
            stage = .connecting
            RawRelay.connect(guest: context, reader: self, to: destination.server)
        }
    }

    /// The sniffer and the resolver give names lowercased, as `Secrets` keeps its hosts.
    private func opens(_ serverName: String) -> Bool {
        state.secrets.hasSecret(for: serverName) && destination.names.contains(serverName)
    }
}
