internal import HangarPackets
internal import NIOCore
internal import NIOPosix

/// A diverted connection that isn't opened: its bytes go to the server it was meant for, as they are.
enum RawRelay {
    static func connect(guest: ChannelHandlerContext, reader: ClientHelloReader, to server: TCPRedirect.Endpoint) {
        let guestChannel = guest.channel
        let address = try? SocketAddress(ipAddress: IPv4Address(server.address).description, port: Int(server.port))
        guard let address else { return guestChannel.close(promise: nil) }

        ClientBootstrap(group: guestChannel.eventLoop)
            .connect(to: address)
            .assumeIsolated()
            .whenComplete { result in
                switch result {
                case .success(let serverChannel):
                    join(guest: guest, reader: reader, server: serverChannel)
                case .failure:
                    guestChannel.close(promise: nil)
                }
            }
    }

    private static func join(guest: ChannelHandlerContext, reader: ClientHelloReader, server: any Channel) {
        let (toServer, toGuest) = Relay.pair()
        do {
            try guest.pipeline.syncOperations.addHandler(toServer, position: .after(reader))
            try server.pipeline.syncOperations.addHandler(toGuest)
        } catch {
            guest.channel.close(promise: nil)
            server.close(promise: nil)
            return
        }
        server.writeAndFlush(reader.startPassing(), promise: nil)
    }
}

/// Two handlers that pass bytes between two channels on the same event loop, reading from one only while the other
/// takes writes, and closing both when either closes.
final class Relay: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var partner: Relay?
    private var context: ChannelHandlerContext?
    private var isPartnerWaiting = false

    static func pair() -> (Relay, Relay) {
        let first = Relay()
        let second = Relay()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.write(unwrapInboundIn(data))
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.flush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.context?.close(promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { partner?.context?.read() }
    }

    func read(context: ChannelHandlerContext) {
        if partner?.context?.channel.isWritable ?? true { context.read() }
    }

    private func write(_ bytes: ByteBuffer) {
        context?.write(wrapOutboundOut(bytes), promise: nil)
    }

    private func flush() {
        context?.flush()
    }
}
