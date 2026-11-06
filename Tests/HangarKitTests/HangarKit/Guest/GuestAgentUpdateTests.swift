import Foundation
import HangarSupport
import Testing

@testable import HangarKit

struct GuestAgentUpdateTests {
    private let agent = "/tmp/hangar-agent-new-1"
    private let passwordLine = Data("secret\n".utf8)
    private let sha256 = String(repeating: "0123456789abcdef", count: 4)

    private func finished(_ exitCode: Int32?, _ errors: String) -> GuestAgentUpdate.Finished {
        GuestAgentUpdate.Finished(exitCode: exitCode, errors: Data(errors.utf8))
    }

    private func problem(_ exitCode: Int32?, _ errors: String, gavePassword: Bool = false) -> (any Error)? {
        GuestAgentUpdate.problem(of: finished(exitCode, errors), gavePassword: gavePassword, vm: "deb")
    }

    @Test func linuxTriesSudoWithoutAPasswordFirstAndThenGivesItOnInput() {
        let first = GuestAgentUpdate.updateCommand(for: .linux, agent: agent, sha256: sha256, passwordLine: nil)
        let retry = GuestAgentUpdate.updateCommand(
            for: .linux, agent: agent, sha256: sha256, passwordLine: passwordLine)

        let update = [agent, "update", "--sha256", sha256]
        #expect(first.arguments == ["/usr/bin/env", "LC_ALL=C", "sudo", "-n", "--"] + update)
        #expect(first.input == nil)
        #expect(retry.arguments == ["/usr/bin/env", "LC_ALL=C", "sudo", "-S", "-p", "", "--"] + update)
        #expect(retry.input == passwordLine)
    }

    @Test func macOSGetsThePasswordOnInputOrAnEmptyInput() {
        let first = GuestAgentUpdate.updateCommand(for: .macOS, agent: agent, sha256: sha256, passwordLine: nil)
        let retry = GuestAgentUpdate.updateCommand(
            for: .macOS, agent: agent, sha256: sha256, passwordLine: passwordLine)

        #expect(first.arguments == [agent, "update", "--sha256", sha256])
        #expect(first.input == Data())
        #expect(retry.input == passwordLine)
    }

    @Test func windowsRunsTheCopyWithoutInputAndLetsWindowsAsk() {
        let path = #"C:\Users\admin\AppData\Local\Temp\hangar-agent-new-1.exe"#

        let command = GuestAgentUpdate.updateCommand(for: .windows, agent: path, sha256: sha256, passwordLine: nil)

        #expect(command.arguments == [path, "update", "--sha256", sha256])
        #expect(command.input == nil)
    }

    @Test func theAgentsSHA256IsLowercaseHexAsTheGuestRequires() throws {
        let agent = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-agent-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: agent)
        defer { try? FileManager.default.removeItem(at: agent) }

        let hex = try GuestAgentUpdate.sha256(of: agent)

        #expect(hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func onlyWindowsWaitsLongForTheUserToAllowTheUpdate() {
        let windows = GuestAgentUpdate.startWait(on: .windows, vm: "win")
        let linux = GuestAgentUpdate.startWait(on: .linux, vm: "deb")

        #expect(windows.seconds == GuestAgentUpdate.permissionPromptWait)
        #expect(windows.silence.contains("click Yes"))
        #expect(linux.seconds == GuestCopy.receiveTimeout)
        #expect(linux.silence == "'deb' stopped answering during the agent's update.")
    }

    @Test func aStartedUpdateOrACutConnectionIsNoProblem() {
        #expect(problem(0, "") == nil)
        #expect(problem(nil, "") == nil)
    }

    @Test func theAgentsPasswordSentenceAsksForOneAndThenSaysItWasWrong() {
        let sentence = "A password is needed to update Hangar's agent.\n"

        #expect(problem(2, sentence) as? GuestAgentUpdate.Failure == .passwordNeeded)
        #expect(problem(2, sentence, gavePassword: true) as? GuestAgentUpdate.Failure == .wrongPassword)
    }

    @Test func sudosPasswordMessagesAskForOneAndThenSayItWasWrong() {
        let missing = "sudo: a password is required\n"
        let wrong = "Sorry, try again.\nsudo: no password was provided\nsudo: 1 incorrect password attempt\n"

        #expect(problem(1, missing) as? GuestAgentUpdate.Failure == .passwordNeeded)
        #expect(problem(1, wrong, gavePassword: true) as? GuestAgentUpdate.Failure == .wrongPassword)
    }

    @Test func anyOtherFailureIsTheGuestsOwnSentenceWithoutThePrefix() throws {
        let refused = try #require(
            problem(1, "hangar-agent: The administrator prompt in the guest was declined.\n") as? HangarError)
        let otherCode = try #require(
            problem(2, "hangar-agent: An update of Hangar's agent is already running.") as? HangarError)
        let silent = try #require(problem(3, "") as? HangarError)

        #expect(refused.message == "The administrator prompt in the guest was declined.")
        #expect(otherCode.message == "An update of Hangar's agent is already running.")
        #expect(silent.message == "The agent in 'deb' couldn't start its update (exit code 3).")
    }

    @Test func aChangedCopyOrAMissingAdministratorIsNotAboutThePassword() throws {
        let changed = "hangar-agent: The copied agent changed before it could be installed.\n"
        let notAdmin = "hangar-agent: Updating Hangar's agent needs an administrator account in the VM.\n"

        let changedProblem = try #require(problem(1, changed) as? HangarError)
        let notAdminProblem = try #require(problem(2, notAdmin) as? HangarError)

        #expect(changedProblem.message == "The copied agent changed before it could be installed.")
        #expect(notAdminProblem.message == "Updating Hangar's agent needs an administrator account in the VM.")
    }

    @Test func windowsTempFolderMustBeAPlainAbsolutePath() {
        let printed = Data((#"C:\Users\Jane Doe\AppData\Local\Temp"# + "\r\n").utf8)

        #expect(GuestAgentUpdate.windowsTempFolder(from: printed) == #"C:\Users\Jane Doe\AppData\Local\Temp"#)
        #expect(GuestAgentUpdate.windowsTempFolder(from: Data("%TEMP%\r\n".utf8)) == nil)
        #expect(GuestAgentUpdate.windowsTempFolder(from: Data(#"C:\Temp" & calc"#.utf8)) == nil)
        #expect(GuestAgentUpdate.windowsTempFolder(from: Data(#"\\server\share"#.utf8)) == nil)
    }

    @Test func onlyAnAnsweringAgentWithCopyInThatIsOlderIsUpdatedInPlace() {
        #expect(!GuestAgentUpdate.canUpdate(from: nil))
        #expect(!GuestAgentUpdate.canUpdate(from: GuestSetup.firstCopyAgentVersion - 1))
        #expect(GuestAgentUpdate.canUpdate(from: GuestSetup.firstCopyAgentVersion))
        #expect(!GuestAgentUpdate.canUpdate(from: GuestSetup.agentVersion))
        #expect(!GuestAgentUpdate.canUpdate(from: GuestSetup.agentVersion + 1))
    }
}
