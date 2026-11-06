import Foundation
import Testing

@testable import HangarKit

struct GuestAgentTests {
    @Test func guestReportsAreBoundedAndAge() {
        var reader = GuestReportReader()
        let start = Date()
        reader.feed(
            Array(#"{"memory":{"total":8589934592,"used":2147483648},"extra":true,"version":5}"#.utf8) + [10],
            now: start)
        #expect(
            reader.report(at: start)
                == GuestReport(memory: GuestMemory(used: 2_147_483_648, total: 8_589_934_592), agentVersion: 5))

        reader.feed(
            Array(#"{"memory":{"total":100,"used":50},"version":3}"#.utf8) + [10], now: start.addingTimeInterval(0.1))
        #expect(reader.report(at: start.addingTimeInterval(0.1))?.memory.total == 8_589_934_592)
        #expect(reader.report(at: start.addingTimeInterval(11)) == nil)

        reader.feed(
            Array(#"{"memory":{"total":100,"used":50},"version":3}"#.utf8) + [10], now: start.addingTimeInterval(1))
        #expect(reader.report(at: start.addingTimeInterval(1))?.agentVersion == 3)

        var strict = GuestReportReader()
        for line in [
            #"{"memory":{"total":4,"used":1}}"#, #"{"memory":{"total":10,"used":20}}"#,
            #"{"memory":{"total":true,"used":0}}"#,
            #"{"memory":{"total":-1,"used":0}}"#, #"{"memory":{"total":2199023255553,"used":1}}"#, "garbage",
            #"{"memory":{"total":4,"used":1},"version":true}"#, #"{"memory":{"total":4,"used":1},"version":1.5}"#,
            #"{"memory":{"total":4,"used":1},"version":-1}"#, #"{"memory":{"total":4,"used":1},"version":"1"}"#,
            #"{"memory":{"total":4,"used":1},"version":1000001}"#,
        ] {
            strict.feed(Array(line.utf8) + [10], now: start)
        }
        #expect(strict.report(at: start) == nil)

        strict.feed(
            [UInt8](repeating: UInt8(ascii: "x"), count: 10_000) + Array(#"{"memory":{"total":4,"used":1}}"#.utf8) + [
                10
            ], now: start)
        #expect(strict.report(at: start) == nil)

        strict.feed(Array(#"{"memory":{"total":4,"used":1},"version":2}"#.utf8) + [10], now: start)
        let report = GuestReport(memory: GuestMemory(used: 1, total: 4), agentVersion: 2)
        #expect(strict.report(at: start) == report)
    }

    @Test func onlyALinuxAgentWithoutAScreenSaysSo() {
        let start = Date()
        var linux = GuestReportReader()
        var older = GuestReportReader()
        var garbled = GuestReportReader()

        linux.feed(Array(#"{"memory":{"total":4,"used":1},"screen":false,"version":12}"#.utf8) + [10], now: start)
        older.feed(Array(#"{"memory":{"total":4,"used":1},"version":11}"#.utf8) + [10], now: start)
        garbled.feed(Array(#"{"memory":{"total":4,"used":1},"screen":0,"version":12}"#.utf8) + [10], now: start)

        #expect(linux.report(at: start)?.hasScreen == false)
        #expect(older.report(at: start)?.hasScreen == nil)
        #expect(older.report(at: start)?.agentVersion == 11)
        #expect(garbled.report(at: start) == nil)
    }

    @Test func controlRepliesCarryOnlyPlausibleReports() throws {
        let report = GuestReport(memory: GuestMemory(used: 1, total: 4), agentVersion: 2)
        let withoutScreen = GuestReport(memory: GuestMemory(used: 1, total: 4), agentVersion: 12, hasScreen: false)
        for reply in [ControlReply.report(report), .report(withoutScreen), .report(nil)] {
            let line = try JSONEncoder().encode(reply)
            #expect(try JSONDecoder().decode(ControlReply.self, from: line) == reply)
        }

        for json in [
            #"{"version":-1,"memory":{"total":4,"used":1}}"#,
            #"{"version":1.5,"memory":{"total":4,"used":1}}"#,
            #"{"version":1000001,"memory":{"total":4,"used":1}}"#,
            #"{"version":2,"memory":{"total":4,"used":5}}"#,
            #"{"version":2,"memory":{"total":0,"used":0}}"#,
            #"{"version":2,"memory":{"total":2199023255553,"used":1}}"#,
            #"{"version":2,"memory":{"total":4,"used":-1}}"#,
            #"{"version":2,"memory":{"total":4.5,"used":1}}"#,
            #"{"memory":{"total":4,"used":1}}"#,
        ] {
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(GuestReport.self, from: Data(json.utf8)) }
        }
    }

    @Test func aMissingGuestFileIsAnError() {
        #expect(throws: (any Error).self) { try GuestFiles.text("linux/missing.sh") }
    }
}
