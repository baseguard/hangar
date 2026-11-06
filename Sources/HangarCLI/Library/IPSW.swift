import ArgumentParser
import Foundation
import HangarKit

struct IPSW: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ipsw", abstract: "Show the newest macOS that Apple offers for this Mac, with its download link.")

    func run() throws {
        runMain {
            let latest = try await MacInstaller.latestRestoreImage()
            print("macOS \(latest.version) (\(latest.buildVersion))")
            print(latest.url.absoluteString)
        }
    }
}
