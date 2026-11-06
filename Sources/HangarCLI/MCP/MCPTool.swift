import MCP

/// A `hangar` command offered to an AI agent over MCP: its name, what it does, the arguments it takes and the command
/// line they make.
struct MCPTool: Sendable {
    /// A `hangar` command line, and how long it may run when it runs commands in a guest.
    struct Invocation: Equatable, Sendable {
        var arguments: [String]
        var timeoutSeconds: Int?
    }

    let name: String
    let description: String
    /// Reads only, so a client may run it without asking.
    var isReadOnly = false
    /// A client should ask first: it can't be undone, can lift a VM's limits or writes files on this Mac.
    var isDestructive = false
    let properties: [String: Value]
    var required: [String] = []
    let invocation: @Sendable (MCPArguments) throws -> Invocation

    var definition: Tool {
        let schema: Value = [
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": false,
        ]
        return Tool(
            name: name, description: description, inputSchema: schema,
            annotations: .init(readOnlyHint: isReadOnly, destructiveHint: isDestructive))
    }
}

/// Schema pieces for the tools' arguments.
enum MCPSchema {
    static func string(_ description: String) -> Value {
        ["type": "string", "description": .string(description)]
    }

    static func integer(_ description: String) -> Value {
        ["type": "integer", "description": .string(description)]
    }

    static func boolean(_ description: String) -> Value {
        ["type": "boolean", "description": .string(description)]
    }

    static func strings(_ description: String) -> Value {
        ["type": "array", "items": ["type": "string"], "description": .string(description)]
    }

    static func oneOf(_ values: [String], _ description: String) -> Value {
        ["type": "string", "enum": .array(values.map { .string($0) }), "description": .string(description)]
    }

    static let vm = string("The VM's name, as list_vms shows it.")
}
