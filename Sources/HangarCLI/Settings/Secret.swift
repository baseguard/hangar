import ArgumentParser
import Darwin
import Foundation
import HangarKit
import HangarSecrets
import HangarSupport

struct Secret: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Give a VM secrets it uses without ever holding them.",
        discussion: """
            Examples:
              hangar secret set deb GITHUB_TOKEN --host api.github.com
                  Asks for the token. Programs in deb see GITHUB_TOKEN set to a
                  placeholder, which Hangar replaces with the token on requests to
                  api.github.com.
              gh auth token | hangar secret set deb GITHUB_TOKEN --host api.github.com \\
                --header 'Authorization: Bearer %s' --value-stdin
                  Also put the token in that header of every request to the host.
              hangar secret list deb
              hangar secret remove deb GITHUB_TOKEN

            The value stays in your Keychain. Hangar opens HTTPS only to the hosts \
            of a secret, with a certificate authority of the VM's own that its \
            agent trusts, and puts the value where the placeholder is in a header, \
            never in a URL or a body. A value in the headers of the host's answer \
            becomes the placeholder again. A placeholder sent to another host is \
            refused. Needs Hangar's managed network and agent 18.
            """,
        subcommands: [Set.self, List.self, Remove.self]
    )

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add or change a secret.")

        @Argument(help: ArgumentHelp("The VM.", valueName: "vm")) var vm: String
        @Argument(help: ArgumentHelp("The variable the VM sees, like GITHUB_TOKEN.", valueName: "name"))
        var name: String
        @Option(
            name: .customLong("host"),
            help: ArgumentHelp(
                "A host the secret is for; repeat for more. Left out with --header, a secret the VM has keeps its own.",
                valueName: "host"))
        var hosts: [String] = []
        @Option(
            help: ArgumentHelp(
                "A header set on every request to the hosts, %s for the secret.", valueName: "name: value"))
        var header: String?
        @Flag(help: "Read the value from standard input.") var valueStdin = false

        func run() throws {
            let bundle = try VMLibrary.bundle(named: vm)
            let rule = try ruleToSave(in: bundle)
            if hosts.isEmpty, !rule.hosts.isEmpty {
                printError("\(name) is sent to \(rule.hosts.joined(separator: ", ")) only; give --host to change that.")
            }
            let saved = try VMSecrets.set(rule, value: try readValue(), in: bundle)
            let live = try VMSecrets.applyLive(to: bundle) ? " The running VM has it now." : ""
            print("Saved \(saved.name) for \(saved.hosts.joined(separator: ", ")).\(live)")
            print("Programs in \(vm) see \(saved.name)=\(saved.placeholder)")
        }

        private func ruleToSave(in bundle: VMBundle) throws -> SecretRule {
            let givenHeader = try header.map(Self.header)
            let existing = try bundle.loadConfig().secrets?.rules.first { $0.name == name }
            return SecretRule.toSave(name: name, hosts: hosts, header: givenHeader, replacing: existing)
        }

        private func readValue() throws -> String {
            if valueStdin {
                // The whole input, unlike a password's one line: a value with a line break is refused by validate.
                let input = FileHandle.standardInput.readDataToEndOfFile()
                return String(decoding: input, as: UTF8.self).trimmingCharacters(in: .newlines)
            }
            guard let value = askHidden("Value of \(name): ") else {
                throw HangarError("Could not read the value. Pipe it in with --value-stdin.")
            }
            return value
        }

        private static func header(_ text: String) throws -> SecretRule.Header {
            let parts = text.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { throw ValidationError("Give the header as 'Name: value with %s'.") }
            return SecretRule.Header(name: parts[0], format: parts[1])
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show a VM's secrets, without their values.", aliases: ["ls"])

        @Argument(help: ArgumentHelp("The VM.", valueName: "vm")) var vm: String

        func run() throws {
            guard let settings = try VMLibrary.bundle(named: vm).loadConfig().secrets, !settings.rules.isEmpty else {
                return print("'\(vm)' has no secrets.")
            }
            let withValues = try SecretValues.namesWithValues(in: settings)
            for rule in settings.rules {
                let value =
                    withValues.contains(rule.name)
                    ? rule.placeholder : "no value yet: hangar secret set \(vm) \(rule.name) --value-stdin"
                print("\(rule.name)  \(rule.hosts.joined(separator: ", "))  \(places(rule))  \(value)")
            }
        }

        private func places(_ rule: SecretRule) -> String {
            var places = ["headers"]
            if let header = rule.header { places.append("sets \(header.name)") }
            return places.joined(separator: ", ")
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a secret and its value.", aliases: ["rm"])

        @Argument(help: ArgumentHelp("The VM.", valueName: "vm")) var vm: String
        @Argument(help: ArgumentHelp("The secret's name.", valueName: "name")) var name: String

        func run() throws {
            let bundle = try VMLibrary.bundle(named: vm)
            try VMSecrets.remove(name, from: bundle)
            let live = try VMSecrets.applyLive(to: bundle) ? " The running VM no longer has it." : ""
            print("Removed \(name).\(live)")
        }
    }
}
