import Testing

@testable import HangarKit

struct WindowsInstallerTests {
    @Test func windowsComputerNames() {
        #expect(WindowsInstaller.computerName(for: "win2") == "WIN2")
        #expect(WindowsInstaller.computerName(for: "2025") == "WIN-2025")
        #expect(WindowsInstaller.computerName(for: "my_windows.vm") == "MY-WINDOWS-VM")
        #expect(WindowsInstaller.computerName(for: "a-very-long-windows-machine") == "A-VERY-LONG-WIN")
        #expect(WindowsInstaller.computerName(for: "--") == "HANGAR-VM")
    }

    @Test(arguments: ["win2", "2025", "x", "a-very-long-windows-machine-"])
    func windowsComputerNamesFollowTheRules(_ name: String) {
        let computer = WindowsInstaller.computerName(for: name)

        #expect(computer.count <= 15)
        #expect(!computer.hasSuffix("-"))
        #expect(computer.contains { $0.isLetter })
    }

    @Test func xMLEscapingAndAnswerFile() {
        #expect(WindowsInstaller.xmlEscaped(#"a&b<c>"d"#) == "a&amp;b&lt;c&gt;&quot;d")

        let account = WindowsInstaller.Account(username: "admin", password: #"p&ss<word>"#)
        let xml = WindowsMedia.answerFile(computerName: "WIN-2026", account: account, language: "en-US")
        #expect(xml.contains("p&amp;ss&lt;word&gt;"))
        #expect(!xml.contains("p&ss<word>"))
        #expect(xml.contains("<ComputerName>WIN-2026</ComputerName>"))
        #expect(xml.contains("<fDenyTSConnections>false</fDenyTSConnections>"))

        let closed = WindowsMedia.answerFile(
            computerName: "WIN-2026",
            account: WindowsInstaller.Account(username: "admin", password: "x", remoteDesktop: false),
            language: "en-US")
        #expect(closed.contains("<fDenyTSConnections>true</fDenyTSConnections>"))
    }

    @Test func theAnswerFilesRunTheAgentInWindowsPEAndBeforeTheFirstSignIn() {
        let account = WindowsInstaller.Account(username: "admin", password: "x")

        let winPE = WindowsMedia.winPEAnswerFile(language: "en-US")
        let windows = WindowsMedia.answerFile(computerName: "WIN", account: account, language: "en-US")

        #expect(
            winPE.contains(
                #"start &quot;&quot; /wait %i:\hangar\hangar-agent.exe winpe-install %i:) &amp; wpeutil shutdown"#))
        #expect(windows.contains(#"<Path>&quot;C:\Program Files\Hangar\hangar-agent.exe&quot; setup</Path>"#))
    }
}
