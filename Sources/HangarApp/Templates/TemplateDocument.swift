import HangarKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Declared in HangarApp-Info.plist, so Finder opens .hangarvm files with Hangar.
    nonisolated static let hangarTemplate = UTType(exportedAs: "io.baseguard.hangar.template")
}

nonisolated struct TemplateDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.hangarTemplate]

    let template: VMTemplate

    init(template: VMTemplate) {
        self.template = template
    }

    init(configuration: ReadConfiguration) throws {
        template = try VMTemplate.decode(configuration.file.regularFileContents ?? Data())
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try template.encoded())
    }
}
