import Foundation
import HangarSupport
import Testing

@testable import HangarKit

@Suite(.temporaryHangarHome)
struct MCPCommandTests {
    private let handshake =
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#

    /// The answers by request ID; calls run side by side, so they come in any order.
    private func answers(to lines: [String]) throws -> [String: [String: Any]] {
        let result = try HangarCommand.run(["mcp"], input: lines.joined(separator: "\n") + "\n")
        var answers: [String: [String: Any]] = [:]
        for line in result.output.split(separator: "\n") {
            let message = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            answers["\(message["id"] ?? "none")"] = message
        }
        return answers
    }

    private func toolText(_ answer: [String: Any]?) throws -> (text: String, isError: Bool) {
        let result = try #require(answer?["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        return (try #require(content.first?["text"] as? String), try #require(result["isError"] as? Bool))
    }

    @Test func anAgentSeesHangarsToolsAfterTheHandshake() throws {
        let answers = try answers(to: [
            handshake, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        ])

        let started = try #require(answers["1"]?["result"] as? [String: Any])
        let tools = try #require((answers["2"]?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let runCommand = try #require(tools.first { $0["name"] as? String == "run_command" })
        let schema = try #require(runCommand["inputSchema"] as? [String: Any])

        #expect(answers.count == 2)
        #expect(started["protocolVersion"] as? String == "2025-03-26")
        #expect(schema["required"] as? [String] == ["vm", "command"])
        #expect(!tools.contains { $0["name"] as? String == "delete_vm" })
    }

    @Test func toolsThatLiftLimitsOrWriteOnTheMacAskFirst() throws {
        let answers = try answers(to: [handshake, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#])

        let tools = try #require((answers["2"]?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let asking = tools.filter { ($0["annotations"] as? [String: Any])?["destructiveHint"] as? Bool == true }

        #expect(
            Set(asking.compactMap { $0["name"] as? String })
                == ["create_vm", "restore_snapshot", "save_template", "change_vm", "copy_files", "traffic_policy"])
    }

    @Test func anOverlongLineIsRefusedAndTheNextOneStillAnswered() throws {
        let overlong = String(repeating: " ", count: 1 << 20) + "{}"

        let answers = try answers(to: [handshake, overlong, #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#])

        #expect((answers["<null>"]?["error"] as? [String: Any])?["code"] as? Int == -32600)
        #expect(answers["2"]?["result"] != nil)
    }

    @Test func aRequestIDThatIsNeitherStringNorNumberIsRefused() throws {
        let answers = try answers(to: [handshake, #"{"jsonrpc":"2.0","id":[2],"method":"ping"}"#])

        #expect((answers["<null>"]?["error"] as? [String: Any])?["code"] as? Int == -32600)
    }

    @Test func aToolRunsHangarsCommandAndPassesOnItsError() throws {
        _ = try TestVM.make(.linux, named: "box")

        let answers = try answers(to: [
            handshake,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run_command","arguments":{"vm":"box","command":"uname -a"}}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_vms","arguments":{}}}"#,
        ])
        let stopped = try toolText(answers["2"])
        let listed = try toolText(answers["3"])

        #expect(stopped.isError)
        #expect(stopped.text.contains("'box' isn't running. Start it: hangar run box"))
        #expect(!listed.isError)
        #expect(listed.text.contains(#""name" : "box""#))
    }

    @Test func anArgumentCantTurnIntoAnOption() throws {
        let answers = try answers(to: [
            handshake,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"stop_vm","arguments":{"vm":"--all"}}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"change_vm","arguments":{"vm":"box","cpu":2.5}}}"#,
        ])

        let option = try toolText(answers["2"])
        let fraction = try toolText(answers["3"])

        #expect(option.isError && option.text == #"vm can't start with "-"."#)
        #expect(fraction.isError && fraction.text == "cpu must be a whole number.")
    }

    @Test func unknownMethodsAndToolsAreProtocolErrors() throws {
        let answers = try answers(to: [
            handshake, #"{"jsonrpc":"2.0","id":2,"method":"resources/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"delete_vm","arguments":{"vm":"box"}}}"#,
            "not json",
        ])

        #expect((answers["2"]?["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect((answers["3"]?["error"] as? [String: Any])?["code"] as? Int == -32602)
        #expect((answers["<null>"]?["error"] as? [String: Any])?["code"] as? Int == -32700)
    }
}
