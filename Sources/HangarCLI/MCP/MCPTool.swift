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
    let properties: [String: JSONValue]
    var required: [String] = []
    let invocation: @Sendable (MCPArguments) throws -> Invocation

    var definition: JSONValue {
        [
            "name": .string(name),
            "description": .string(description),
            "inputSchema": [
                "type": "object",
                "properties": .object(properties),
                "required": .array(required.map(JSONValue.string)),
                "additionalProperties": false,
            ],
            "annotations": [
                "readOnlyHint": .bool(isReadOnly),
                "destructiveHint": .bool(isDestructive),
            ],
        ]
    }
}

/// Schema pieces for the tools' arguments.
enum MCPSchema {
    static func string(_ description: String) -> JSONValue {
        ["type": "string", "description": .string(description)]
    }

    static func integer(_ description: String) -> JSONValue {
        ["type": "integer", "description": .string(description)]
    }

    static func boolean(_ description: String) -> JSONValue {
        ["type": "boolean", "description": .string(description)]
    }

    static func strings(_ description: String) -> JSONValue {
        ["type": "array", "items": ["type": "string"], "description": .string(description)]
    }

    static func oneOf(_ values: [String], _ description: String) -> JSONValue {
        ["type": "string", "enum": .array(values.map(JSONValue.string)), "description": .string(description)]
    }

    static let vm = string("The VM's name, as list_vms shows it.")
}
