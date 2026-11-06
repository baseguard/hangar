import ArgumentParser
import Foundation
import HangarKit
import HangarSupport

struct TemplateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "template",
        abstract: "Save a VM's recipe, to make more VMs like it with `hangar create --template`.",
        subcommands: [Save.self]
    )

    struct Save: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Save a VM's recipe to a .hangarvm file.",
            discussion: """
                Examples:
                  hangar template save go go-dev.hangarvm
                  hangar create go2 --template go-dev.hangarvm

                The file holds what the VM is made from, its size and settings, its traffic \
                rules, the secrets it expects and the commands in "setup", which run once \
                through Hangar's agent after its first start. Its disk, addresses, \
                passwords and secret values stay behind.
                """
        )

        @Argument(help: ArgumentHelp("The VM.", valueName: "vm"))
        var name: String

        @Argument(help: ArgumentHelp("The file to write; .hangarvm is added when missing.", valueName: "file"))
        var file: String

        func run() throws {
            let bundle = try VMLibrary.bundle(named: name)
            let template = VMTemplate(savedFrom: try bundle.loadConfig(), diskSize: bundle.diskSize)
            var url = URL(userPath: file)
            if url.pathExtension != VMTemplate.fileExtension { url.appendPathExtension(VMTemplate.fileExtension) }

            try template.write(to: url)

            print("Saved the template of '\(name)' to \(url.path).")
        }
    }
}
