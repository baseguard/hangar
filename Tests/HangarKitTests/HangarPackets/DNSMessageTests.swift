import Testing

@testable import HangarPackets

struct DNSMessageTests {
    @Test func parsesQuestionsAndCompressedAnswers() throws {
        let query = TrafficSamples.dnsQuery("API.github.com")
        let reply = TrafficSamples.dnsAnswer(
            to: query, addresses: ["140.82.121.6", "140.82.121.5"], alias: "github.map.fastly.net")

        let parsedQuery = try #require(DNSMessage(query))
        let answer = try #require(DNSMessage(reply))

        #expect(!parsedQuery.isResponse)
        #expect(parsedQuery.question.name == "api.github.com")
        #expect(answer.isResponse)
        #expect(answer.answers.compactMap(\.alias) == ["github.map.fastly.net"])
        #expect(
            answer.answers.compactMap(\.address).map { IPv4Address($0).description } == [
                "140.82.121.6", "140.82.121.5",
            ])
    }

    @Test func refusalKeepsTheIDAndQuestion() throws {
        let query = TrafficSamples.dnsQuery("evil.example", id: 0xbeef)

        let reply = try #require(DNSMessage.refusal(to: query, code: DNSMessage.nameError))

        let parsed = try #require(DNSMessage(reply))
        #expect(parsed.id == 0xbeef)
        #expect(parsed.isResponse)
        #expect(parsed.responseCode == DNSMessage.nameError)
        #expect(parsed.question.name == "evil.example")
        #expect(parsed.answers.isEmpty)
        #expect(DNSMessage.refusal(to: reply, code: DNSMessage.nameError) == nil)
    }

    @Test func readsServiceTargets() throws {
        var answer = TrafficSamples.dnsQuery("_https._tcp.deb.debian.org", type: DNSMessage.typeSRV)
        answer[2] = 0x81
        answer[3] = 0x80
        answer[7] = 1
        let target: [UInt8] =
            [6] + Array("debian".utf8) + [3] + Array("map".utf8) + [6] + Array("fastly".utf8) + [3] + Array("net".utf8)
            + [0]
        answer += [0xc0, 12, 0, 33, 0, 1, 0, 0, 0, 60, 0, UInt8(6 + target.count), 0, 10, 0, 1, 1, 0xbb] + target

        #expect(DNSMessage(answer)?.answers.first?.alias == "debian.map.fastly.net")
    }

    @Test func namesAreMadePrintable() throws {
        let message = try #require(DNSMessage(TrafficSamples.dnsQuery("a\u{1b}[2Jb.example")))

        #expect(message.question.name == "a?[2jb.example")
    }

    @Test func rejectsLoopsAndTruncation() {
        var looping = TrafficSamples.dnsQuery("a.b")
        looping.replaceSubrange(12..<17, with: [0xc0, 12, 0, 1, 0])

        #expect(DNSMessage(looping) == nil)
        #expect(DNSMessage(Array(TrafficSamples.dnsQuery("github.com").prefix(20))) == nil)
        #expect(DNSMessage([0, 1, 2]) == nil)
    }
}
