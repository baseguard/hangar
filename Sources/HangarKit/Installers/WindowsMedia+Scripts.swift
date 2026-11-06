import Foundation

extension WindowsMedia {
    /// Windows PE gives the media any free drive letter, so each one is tried; `start /wait` makes cmd wait for the
    /// agent, which has no console, before it shuts Windows PE down.
    static var winPEInstallCommand: String {
        let agent = #"%i:\hangar\\#(GuestTools.windowsAgent)"#
        let letters = "C D E F G H I J K L M N O P Q R S T U V W Y Z"
        let install = #"@if exist \#(agent) start "" /wait \#(agent) winpe-install %i:"#
        return "cmd.exe /c (for %i in (\(letters)) do \(install)) & wpeutil shutdown"
    }

    /// Setup runs it as SYSTEM before the first sign-in, so the agent's service and session helper are there for it.
    static let agentSetupCommand = #""C:\Program Files\Hangar\\#(GuestTools.windowsAgent)" setup"#

    static func winPEAnswerFile(language: String) -> String {
        let component = WindowsInstaller.component
        return """
            <?xml version="1.0" encoding="utf-8"?>
            <unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
              <settings pass="windowsPE">
                <\(component("Microsoft-Windows-International-Core-WinPE"))>
                  <SetupUILanguage><UILanguage>\(language)</UILanguage></SetupUILanguage>
                  <InputLocale>\(language)</InputLocale><SystemLocale>\(language)</SystemLocale><UILanguage>\(language)</UILanguage><UserLocale>\(language)</UserLocale>
                </component>
                <\(component("Microsoft-Windows-Setup"))>
                  <RunSynchronous>
                    <RunSynchronousCommand wcm:action="add">
                      <Order>1</Order>
                      <Path>\(WindowsInstaller.xmlEscaped(winPEInstallCommand))</Path>
                    </RunSynchronousCommand>
                  </RunSynchronous>
                  <UserData><AcceptEula>true</AcceptEula></UserData>
                </component>
              </settings>
            </unattend>
            """
    }

    static func answerFile(computerName: String, account: WindowsInstaller.Account, language: String) -> String {
        let component = WindowsInstaller.component
        let escaped = WindowsInstaller.xmlEscaped
        let user = escaped(account.username)
        let password = escaped(account.password)

        return """
            <?xml version="1.0" encoding="utf-8"?>
            <unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
              <settings pass="specialize">
                <\(component("Microsoft-Windows-Shell-Setup"))>
                  <ComputerName>\(escaped(computerName))</ComputerName>
                  <TimeZone>UTC</TimeZone>
                </component>
                <\(component("Microsoft-Windows-TerminalServices-LocalSessionManager"))>
                  <fDenyTSConnections>\(account.remoteDesktop ? "false" : "true")</fDenyTSConnections>
                </component>
                <\(component("Microsoft-Windows-Deployment"))>
                  <RunSynchronous>
                    <RunSynchronousCommand wcm:action="add">
                      <Order>1</Order>
                      <Path>reg add HKLM\\SYSTEM\\CurrentControlSet\\Control\\TimeZoneInformation /v RealTimeIsUniversal /t REG_DWORD /d 1 /f</Path>
                    </RunSynchronousCommand>
                    <RunSynchronousCommand wcm:action="add">
                      <Order>2</Order>
                      <Path>\(escaped(agentSetupCommand))</Path>
                    </RunSynchronousCommand>
                  </RunSynchronous>
                </component>
              </settings>
              <settings pass="oobeSystem">
                <\(component("Microsoft-Windows-International-Core"))>
                  <InputLocale>\(language)</InputLocale><SystemLocale>\(language)</SystemLocale><UILanguage>\(language)</UILanguage><UserLocale>\(language)</UserLocale>
                </component>
                <\(component("Microsoft-Windows-Shell-Setup"))>
                  <OOBE>
                    <HideEULAPage>true</HideEULAPage>
                    <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                    <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                    <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                    <HideLocalAccountScreen>true</HideLocalAccountScreen>
                    <ProtectYourPC>3</ProtectYourPC>
                  </OOBE>
                  <UserAccounts>
                    <LocalAccounts>
                      <LocalAccount wcm:action="add">
                        <Name>\(user)</Name>
                        <Group>Administrators</Group>
                        <Password><Value>\(password)</Value><PlainText>true</PlainText></Password>
                      </LocalAccount>
                    </LocalAccounts>
                  </UserAccounts>
                  <AutoLogon>
                    <Enabled>true</Enabled>
                    <Username>\(user)</Username>
                    <Password><Value>\(password)</Value><PlainText>true</PlainText></Password>
                    <LogonCount>9999</LogonCount>
                  </AutoLogon>
                </component>
              </settings>
            </unattend>
            """
    }
}
