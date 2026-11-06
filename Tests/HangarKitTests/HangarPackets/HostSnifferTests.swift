import Testing

@testable import HangarPackets

struct HostSnifferTests {
    @Test func findsTheServerNameEvenWhenItArrivesInPieces() {
        let hello = TrafficSamples.clientHello(serverName: "API.github.com")

        #expect(HostSniffer.sniff(hello) == .tls(serverName: "api.github.com"))
        #expect(HostSniffer.sniff(Array(hello.prefix(30))) == .needMore)
        #expect(HostSniffer.sniff([0x16]) == .needMore)
    }

    @Test func reassemblesHelloSplitAcrossRecordsAndRefusesToGuess() {
        let hello = TrafficSamples.clientHello(serverName: "api.github.com")
        let split = TrafficSamples.splitRecords(hello, at: 10)

        #expect(HostSniffer.sniff(split) == .tls(serverName: "api.github.com"))
        #expect(HostSniffer.sniff(Array(split.prefix(20))) == .needMore)
        #expect(HostSniffer.sniff(Array(split.prefix(15)) + [0x17, 3, 3, 0, 1, 0]) == .tls(serverName: nil))
        #expect(HostSniffer.sniff(TrafficSamples.clientHello(serverName: nil)) == .tls(serverName: nil))
        #expect(
            HostSniffer.sniff(TrafficSamples.clientHello(serverName: "bad\u{1b}[31m.example"))
                == .tls(serverName: "bad?[31m.example"))
    }

    @Test func readsTheOfferedProtocols() {
        let hello = TrafficSamples.clientHello(serverName: "api.github.com", protocols: ["h2", "http/1.1"])

        #expect(HostSniffer.offeredProtocols(hello) == ["h2", "http/1.1"])
        #expect(HostSniffer.sniff(hello) == .tls(serverName: "api.github.com"))
        #expect(HostSniffer.offeredProtocols(TrafficSamples.clientHello(serverName: "api.github.com")).isEmpty)
        #expect(HostSniffer.offeredProtocols(Array(hello.prefix(30))).isEmpty)
    }

    @Test func aRequestLineIsHTTPAndItsHeadIsReadStrictly() {
        func request(_ head: String) -> HostSniffer.Request? { HostSniffer.request(Array(head.utf8)[...]) }

        #expect(request("GET /\r\nHost: a.example\r\n\r\n") == nil)

        #expect(HostSniffer.sniff(Array("PROPFIND /dav HTTP/1.1\r\n".utf8)) == .http)
        #expect(HostSniffer.sniff(Array("GE".utf8)) == .needMore)
        #expect(HostSniffer.sniff(Array("SSH-2.0-OpenSSH_9.9\r\n".utf8)) == .unknown)

        let get = request("GET /some/path?x=1 HTTP/1.1\r\nUser-Agent: curl\r\nHost: Example.com:8080\r\n\r\n")
        #expect(get?.host == "example.com")
        #expect(get?.path == "/some/path?x=1")
        #expect(request("CONNECT pypi.org:443 HTTP/1.1\r\n\r\n")?.host == "pypi.org")
        #expect(request("GET http://good.example/a HTTP/1.1\r\nHost: Good.example\r\n\r\n")?.host == "good.example")
        for smuggled in [
            "GET / HTTP/1.1\r\nHost: a.example\r\nHost: b.example\r\n\r\n",
            "POST / HTTP/1.1\r\nHost: a.example\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n",
            "POST / HTTP/1.1\r\nHost: a.example\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n",
            "POST / HTTP/1.1\r\nHost: a.example\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
            "GET http://good.example/ HTTP/1.1\r\nHost: evil.example\r\n\r\n",
            "PUT /u HTTP/1.1\r\nContent-Length: x\r\n\r\n",
        ] {
            #expect(request(smuggled) == nil, "\(smuggled)")
        }

        #expect(
            request("POST /u HTTP/1.1\r\nHost: a.example\r\nContent-Length: 12\r\n\r\n")
                == HostSniffer.Request(
                    method: "POST", host: "a.example", path: "/u", contentLength: 12, isChunked: false, upgrades: false)
        )
        #expect(request("PUT /u HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")?.isChunked == true)
    }
}
