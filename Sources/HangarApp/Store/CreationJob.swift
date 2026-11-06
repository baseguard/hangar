import Foundation
import HangarKit
import HangarSupport

struct CreationJob: Identifiable {
    let id = UUID()
    let name: String
    let source: VMSource
    let options: CreateOptions
    let openDisplay: ((String) -> Void)?
    var progress = CreationProgress(phase: "Starting")
    var error: String?

    var os: GuestOS { source.os }
}
