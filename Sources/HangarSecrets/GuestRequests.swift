import Foundation
internal import HangarTraffic
internal import NIOCore
internal import NIOHTTP1

/// The guest's requests on an opened connection: each is checked and rewritten (`RequestRewriter`), then sent to the
/// server, or answered here when refused. The guest is read only while the server takes writes.
final class GuestRequests: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let server: any Channel
    private let serverName: String
    private let state: SecretsProxyServer.State
    /// Made for each request, so a secret removed or changed meanwhile isn't put in on a connection kept open.
    private var rewriter: RequestRewriter
    private let report: @Sendable (TrafficEvent) -> Void
    /// After a refusal, until the request ends.
    private var isDropping = false
    private var request: (method: String, path: String) = ("", "")
    private var version = HTTPVersion.http1_1

    init(server: any Channel, serverName: String, state: SecretsProxyServer.State) {
        self.server = server
        self.serverName = serverName
        self.state = state
        report = state.report
        rewriter = Self.rewriter(for: serverName, state: state)
    }

    private static func rewriter(for serverName: String, state: SecretsProxyServer.State) -> RequestRewriter {
        let secrets = state.secrets
        return RequestRewriter(serverName: serverName, rules: secrets.rules, values: secrets.values)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestStarted(head, context: context)
        case .body(let bytes):
            guard !isDropping else { return }
            server.write(HTTPClientRequestPart.body(.byteBuffer(bytes)), promise: nil)
        case .end(let trailers):
            // Trailers go as they are: they can't name the host, and a placeholder in one reaches the server unchanged.
            if !isDropping { server.writeAndFlush(HTTPClientRequestPart.end(trailers), promise: nil) }
            isDropping = false
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        server.flush()
        if !server.isWritable { _ = context.channel.setOption(.autoRead, value: false) }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { _ = server.setOption(.autoRead, value: true) }
        context.fireChannelWritabilityChanged()
    }

    func channelInactive(context: ChannelHandlerContext) {
        server.close(promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }

    private func requestStarted(_ head: HTTPRequestHead, context: ChannelHandlerContext) {
        request = (head.method.rawValue, head.uri)
        version = head.version
        rewriter = Self.rewriter(for: serverName, state: state)
        switch rewriter.rewrite(Self.requestHead(head)) {
        case .refuse(let refusal):
            refuse(refusal, context: context)
        case .forward(let rewritten, let used):
            if !used.isEmpty { reportUse(of: used) }
            server.write(HTTPClientRequestPart.head(nioHead(rewritten)), promise: nil)
        }
    }

    /// Answers the guest itself, since the request never reaches the server.
    private func refuse(_ refusal: RequestRewriter.Refusal, context: ChannelHandlerContext) {
        isDropping = true
        report(
            .secretsRefused(
                host: rewriter.serverName, method: request.method, path: request.path, reason: refusal.message,
                now: Date()))
        // HTTP/1.1 can't tell the rest of a refused request from the next one, so both connections close. An HTTP/2
        // stream just ends once the guest has sent the rest, and the server's stream closes with it (channelInactive);
        // closing either now would reset the guest's stream and cut off the answer.
        let closesConnection = version.major < 2
        let (head, body) = Self.refusalResponse(refusal, closesConnection: closesConnection)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        let answered = context.writeAndFlush(wrapOutboundOut(.end(nil)))

        guard closesConnection else { return }
        answered.assumeIsolated().whenComplete { _ in context.close(promise: nil) }
        server.close(promise: nil)
    }

    /// A plain-text answer with the refusal's status and reason.
    private static func refusalResponse(
        _ refusal: RequestRewriter.Refusal, closesConnection: Bool
    ) -> (head: HTTPResponseHead, body: ByteBuffer) {
        let body = ByteBuffer(string: refusal.message + "\n")
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: String(body.readableBytes))
        if closesConnection { headers.add(name: "Connection", value: "close") }

        let status = HTTPResponseStatus(statusCode: refusal.status)
        return (HTTPResponseHead(version: .http1_1, status: status, headers: headers), body)
    }

    private static func requestHead(_ head: HTTPRequestHead) -> RequestHead {
        RequestHead(
            method: head.method.rawValue, uri: head.uri,
            fields: head.headers.map { RequestHead.Field($0.name, $0.value) })
    }

    private func nioHead(_ head: RequestHead) -> HTTPRequestHead {
        HTTPRequestHead(
            version: version, method: HTTPMethod(rawValue: head.method), uri: head.uri,
            headers: HTTPHeaders(head.fields.map { ($0.name, $0.value) }))
    }

    private func reportUse(of names: [String]) {
        report(
            .secretsUsed(names, host: rewriter.serverName, method: request.method, path: request.path, now: Date()))
    }
}

/// The server's answers, passed to the guest as they come, with a secret's value in a header put back to its
/// placeholder (`ResponseHeaderScrubber`). The server is read only while the guest takes writes.
final class ServerResponses: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart

    private let guest: any Channel
    private let serverName: String
    private let state: SecretsProxyServer.State
    /// Made for each answer, with the secrets as they are when it starts.
    private var scrubber: ResponseHeaderScrubber
    /// The write that ends the last response; the guest is closed only once it has gone out.
    private var responseEnd: EventLoopFuture<Void>?

    init(guest: any Channel, serverName: String, state: SecretsProxyServer.State) {
        self.guest = guest
        self.serverName = serverName
        self.state = state
        scrubber = Self.scrubber(for: serverName, state: state)
    }

    private static func scrubber(for serverName: String, state: SecretsProxyServer.State) -> ResponseHeaderScrubber {
        let secrets = state.secrets
        return ResponseHeaderScrubber(serverName: serverName, rules: secrets.rules, values: secrets.values)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            responseEnd = nil
            scrubber = Self.scrubber(for: serverName, state: state)
            var masked = head
            masked.headers = scrubbed(head.headers)
            guest.write(HTTPServerResponsePart.head(masked), promise: nil)
        case .body(let bytes):
            guest.write(HTTPServerResponsePart.body(.byteBuffer(bytes)), promise: nil)
        case .end(let trailers):
            responseEnd = guest.writeAndFlush(HTTPServerResponsePart.end(trailers.map(scrubbed)))
            reportMasked()
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        guest.flush()
        if !guest.isWritable { _ = context.channel.setOption(.autoRead, value: false) }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { _ = guest.setOption(.autoRead, value: true) }
        context.fireChannelWritabilityChanged()
    }

    /// A server that closes right after its response would otherwise cut off the part the guest hasn't taken yet.
    func channelInactive(context: ChannelHandlerContext) {
        guard let responseEnd else { return guest.close(promise: nil) }
        let guest = guest
        responseEnd.whenComplete { _ in guest.close(promise: nil) }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }

    private func scrubbed(_ headers: HTTPHeaders) -> HTTPHeaders {
        HTTPHeaders(headers.map { ($0.name, scrubber.scrub(headerValue: $0.value)) })
    }

    /// The traffic log shows a host that sends a value back.
    private func reportMasked() {
        guard !scrubber.masked.isEmpty else { return }
        state.report(.secretsMasked(scrubber.masked.sorted(), host: serverName, now: Date()))
    }
}
