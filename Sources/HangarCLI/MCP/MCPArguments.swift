import HangarSupport

/// A tool call's arguments, read the way `hangar` takes them. A value that starts with "-" is refused, so an argument
/// can't turn into an option: a VM named "--all" would stop every VM.
struct MCPArguments: Sendable {
    let fields: [String: JSONValue]

    func string(_ key: String) throws -> String? {
        guard let value = fields[key], value != .null else { return nil }
        guard let text = value.string else { throw HangarError("\(key) must be a string.") }
        return try checked(text, key)
    }

    func requiredString(_ key: String) throws -> String {
        guard let text = try string(key), !text.isEmpty else { throw HangarError("Give \(key).") }
        return text
    }

    /// The command for the guest's shell goes after the VM, where `hangar exec` reads no options.
    func command(_ key: String) throws -> String {
        guard let text = fields[key]?.string, !text.isEmpty else { throw HangarError("Give \(key).") }
        return text
    }

    func int(_ key: String) throws -> Int? {
        guard let value = fields[key], value != .null else { return nil }
        guard let number = value.int else { throw HangarError("\(key) must be a whole number.") }
        return number
    }

    func bool(_ key: String) throws -> Bool? {
        guard let value = fields[key], value != .null else { return nil }
        guard let flag = value.bool else { throw HangarError("\(key) must be true or false.") }
        return flag
    }

    func strings(_ key: String) throws -> [String] {
        guard let value = fields[key], value != .null else { return [] }
        guard let texts = value.strings else { throw HangarError("\(key) must be a list of strings.") }
        return try texts.map { try checked($0, key) }
    }

    private func checked(_ text: String, _ key: String) throws -> String {
        guard !text.hasPrefix("-") else { throw HangarError("\(key) can't start with \"-\".") }
        return text
    }
}

/// Adds `--name value` to a `hangar` command line when the value was given.
extension [String] {
    mutating func add(_ option: String, _ value: String?) {
        guard let value else { return }
        append(contentsOf: [option, value])
    }

    mutating func add(_ option: String, _ value: Int?) {
        add(option, value.map(String.init))
    }

    mutating func add(_ option: String, onOff value: Bool?) {
        add(option, value.map { $0 ? "on" : "off" })
    }
}
