import HangarKit

/// The `hangar` commands an AI agent can use. Secret values, passwords and deleting VMs stay with the user.
enum MCPTools {
    /// How long run_command waits for a command before it is cut off.
    static let defaultCommandTimeout = 600

    static let all: [MCPTool] = library + running + connecting + network

    private static let library: [MCPTool] = [
        MCPTool(
            name: "list_vms", description: "List the VMs with their system, state, size and IP address, as JSON.",
            isReadOnly: true, properties: [:]
        ) { _ in .init(arguments: ["list", "--json"]) },
        MCPTool(
            name: "get_vm", description: "Show a VM's settings: processors, memory, disk, network and devices.",
            isReadOnly: true, properties: ["vm": MCPSchema.vm], required: ["vm"]
        ) { arguments in .init(arguments: ["info", try arguments.requiredString("vm")]) },
        createVM,
        changeVM,
        MCPTool(
            name: "clone_vm",
            description:
                "Make a new VM as an instant copy of a stopped VM, or of one of its snapshots, with its own MAC and IP address.",
            properties: [
                "vm": MCPSchema.vm, "name": MCPSchema.string("The new VM's name."),
                "snapshot": MCPSchema.string("Copy this snapshot instead of the VM's current disk."),
            ],
            required: ["vm", "name"]
        ) { arguments in
            var command = ["clone", try arguments.requiredString("vm"), try arguments.requiredString("name")]
            command.add("--snapshot", try arguments.string("snapshot"))
            return .init(arguments: command)
        },
        MCPTool(
            name: "save_template",
            description:
                "Save a VM's recipe to a .hangarvm file on this Mac, to make more VMs like it with create_vm's template.",
            isDestructive: true,
            properties: ["vm": MCPSchema.vm, "file": MCPSchema.string("The file to write on this Mac.")],
            required: ["vm", "file"]
        ) { arguments in
            .init(arguments: [
                "template", "save", try arguments.requiredString("vm"), try arguments.requiredString("file"),
            ])
        },
    ]

    private static let createVM = MCPTool(
        name: "create_vm",
        description: """
            Create a VM. Hangar's images are ready in seconds to minutes and sign in as admin, password admin: \
            Linux debian or ubuntu, macOS base (Homebrew) or xcode (Homebrew and Xcode). An image can also be one \
            from a registry (registry/repo:tag) or a .tar file, and a template a .hangarvm file. Windows and \
            installer ISOs need the Hangar app.
            """,
        isDestructive: true,
        properties: [
            "name": MCPSchema.string("The new VM's name: letters, digits, '-' and '_'."),
            "os": MCPSchema.oneOf(["linux", "macos"], "The system; not needed with a template."),
            "image": MCPSchema.string("debian, ubuntu, base, xcode, vanilla, registry/repo:tag or a .tar file."),
            "template": MCPSchema.string("A .hangarvm file on this Mac; the other arguments override it."),
            "cpu": MCPSchema.integer("Processors."),
            "memory": MCPSchema.integer("Memory in GB."),
            "disk": MCPSchema.integer("Disk size in GB."),
        ],
        required: ["name"]
    ) { arguments in
        var command = ["create", try arguments.requiredString("name")]
        command.add("--os", try arguments.string("os"))
        command.add("--image", try arguments.string("image"))
        command.add("--template", try arguments.string("template"))
        command.add("--cpu", try arguments.int("cpu"))
        command.add("--memory", try arguments.int("memory"))
        command.add("--disk", try arguments.int("disk"))
        return .init(arguments: command)
    }

    private static let changeVM = MCPTool(
        name: "change_vm",
        description:
            "Change a VM's processors, memory, disk size, network or autostart. Size changes need the VM stopped.",
        isDestructive: true,
        properties: [
            "vm": MCPSchema.vm, "cpu": MCPSchema.integer("Processors."), "memory": MCPSchema.integer("Memory in GB."),
            "disk": MCPSchema.integer("Grow the disk to this many GB; it can't shrink."),
            "network": MCPSchema.oneOf(
                ["managed", "nat", "none"], "managed: Hangar's network with traffic rules. nat: the system's NAT."),
            "autostart": MCPSchema.boolean("Start the VM in the background whenever the Hangar app opens."),
        ],
        required: ["vm"]
    ) { arguments in
        var command = ["set", try arguments.requiredString("vm")]
        command.add("--cpu", try arguments.int("cpu"))
        command.add("--memory", try arguments.int("memory"))
        command.add("--disk", try arguments.int("disk"))
        command.add("--network", try arguments.string("network"))
        command.add("--autostart", onOff: try arguments.bool("autostart"))
        return .init(arguments: command)
    }

    private static let running: [MCPTool] = [
        MCPTool(
            name: "start_vm", description: "Start a VM in the background, without a window.",
            properties: ["vm": MCPSchema.vm], required: ["vm"]
        ) { arguments in .init(arguments: ["run", try arguments.requiredString("vm"), "--background"]) },
        MCPTool(
            name: "stop_vm", description: "Shut a running VM down, or turn it off at once with force.",
            properties: [
                "vm": MCPSchema.vm, "force": MCPSchema.boolean("Turn it off without waiting for the system."),
            ],
            required: ["vm"]
        ) { arguments in
            var command = ["stop", try arguments.requiredString("vm")]
            if try arguments.bool("force") == true { command.append("--force") }
            return .init(arguments: command)
        },
        MCPTool(
            name: "list_snapshots", description: "List a VM's snapshots.", isReadOnly: true,
            properties: ["vm": MCPSchema.vm], required: ["vm"]
        ) { arguments in .init(arguments: ["snapshot", "list", try arguments.requiredString("vm")]) },
        MCPTool(
            name: "take_snapshot", description: "Take an instant snapshot of a VM's disk, to restore later.",
            properties: [
                "vm": MCPSchema.vm, "snapshot": MCPSchema.string("Its name; the date and time when left out."),
            ],
            required: ["vm"]
        ) { arguments in
            var command = ["snapshot", "take", try arguments.requiredString("vm")]
            if let snapshot = try arguments.string("snapshot") { command.append(snapshot) }
            return .init(arguments: command)
        },
        MCPTool(
            name: "restore_snapshot",
            description: "Put a stopped VM's disk back to a snapshot; what changed since is lost.",
            isDestructive: true,
            properties: ["vm": MCPSchema.vm, "snapshot": MCPSchema.string("The snapshot's name.")],
            required: ["vm", "snapshot"]
        ) { arguments in
            .init(
                arguments: [
                    "snapshot", "restore", try arguments.requiredString("vm"), try arguments.requiredString("snapshot"),
                ])
        },
    ]

    private static let connecting: [MCPTool] = [
        runCommand,
        MCPTool(
            name: "copy_files",
            description: """
                Copy files or folders between this Mac and a running VM. Name a path in the VM as \
                vm:/path, for example deb:/home/admin/report.txt.
                """,
            isDestructive: true,
            properties: [
                "source": MCPSchema.string("A path on this Mac, or vm:/path."),
                "destination": MCPSchema.string("A path on this Mac, or vm:/path."),
            ],
            required: ["source", "destination"]
        ) { arguments in
            .init(arguments: [
                "cp", try arguments.requiredString("source"), try arguments.requiredString("destination"),
            ])
        },
        MCPTool(
            name: "get_ip", description: "Print a running VM's IP address, waiting for it when it just started.",
            isReadOnly: true,
            properties: ["vm": MCPSchema.vm, "wait_seconds": MCPSchema.integer("How long to wait; default 60.")],
            required: ["vm"]
        ) { arguments in
            let wait = try arguments.int("wait_seconds") ?? 60
            return .init(arguments: ["ip", try arguments.requiredString("vm"), "--wait", String(wait)])
        },
    ]

    private static let runCommand = MCPTool(
        name: "run_command",
        description: """
            Run a command line in a running VM through Hangar's agent, as its user (admin on Hangar's images), with \
            the guest's shell (zsh on macOS, sh on Linux, cmd.exe on Windows) and the VM's secret variables. Returns its output and exit code. \
            On Hangar's Linux images and the macOS base and xcode images, sudo needs no password.
            """,
        properties: [
            "vm": MCPSchema.vm, "command": MCPSchema.string("The command line, e.g. apt-get install -y golang."),
            "timeout_seconds": MCPSchema.integer("Stop it after this long; default 600."),
        ],
        required: ["vm", "command"]
    ) { arguments in
        let vm = try arguments.requiredString("vm")
        let os = try VMLibrary.bundle(named: vm).loadConfig().os
        let timeout = try arguments.int("timeout_seconds") ?? defaultCommandTimeout
        return .init(
            arguments: ["exec", vm] + os.shellCommand(try arguments.command("command")), timeoutSeconds: timeout)
    }

    private static let network: [MCPTool] = [
        MCPTool(
            name: "get_traffic",
            description: "Show where a VM's network traffic went: connections, DNS lookups and what was blocked.",
            isReadOnly: true,
            properties: [
                "vm": MCPSchema.vm, "blocked_only": MCPSchema.boolean("Only what was blocked."),
                "summary": MCPSchema.boolean("Totals per host instead of each connection."),
                "count": MCPSchema.integer("How many recent lines; default 50."),
            ],
            required: ["vm"]
        ) { arguments in
            var command = ["traffic", try arguments.requiredString("vm")]
            if try arguments.bool("blocked_only") == true { command.append("--blocked") }
            if try arguments.bool("summary") == true { command.append("--summary") }
            command.add("--count", try arguments.int("count"))
            return .init(arguments: command)
        },
        trafficPolicy,
    ]

    private static let trafficPolicy = MCPTool(
        name: "traffic_policy",
        description: """
            Show or change a VM's traffic rules; with only vm, it shows them. allowlist blocks all but the allowed \
            hosts, blocklist allows all but the blocked ones, monitor only records. A rule is a host with its \
            subdomains (github.com), only the subdomains (*.github.com) or a network (140.82.112.0/20); another \
            VM's address lets the two talk. Changes apply to a running VM at once.
            """,
        isDestructive: true,
        properties: [
            "vm": MCPSchema.vm,
            "mode": MCPSchema.oneOf(["monitor", "allowlist", "blocklist", "off"], "How the rules apply."),
            "allow": MCPSchema.strings("Rules to add to the allow list."),
            "block": MCPSchema.strings("Rules to add to the block list."),
            "remove": MCPSchema.strings("Rules to remove from both lists."),
            "this_mac": MCPSchema.boolean("Allow servers running on this Mac."),
            "other_vms": MCPSchema.boolean("Allow every other VM on Hangar's network."),
            "local_network": MCPSchema.boolean("Allow private addresses outside Hangar's network."),
            "quic": MCPSchema.boolean("Allow QUIC (HTTP/3)."),
            "udp": MCPSchema.boolean("Allow UDP."),
            "isolate": MCPSchema.boolean("Cut the VM off from everything at once."),
        ],
        required: ["vm"]
    ) { arguments in
        var command = ["policy", try arguments.requiredString("vm")]
        command.add("--mode", try arguments.string("mode"))
        for rule in try arguments.strings("allow") { command.add("--allow", rule) }
        for rule in try arguments.strings("block") { command.add("--block", rule) }
        for rule in try arguments.strings("remove") { command.add("--remove", rule) }
        command.add("--host", onOff: try arguments.bool("this_mac"))
        command.add("--vms", onOff: try arguments.bool("other_vms"))
        command.add("--local-network", onOff: try arguments.bool("local_network"))
        command.add("--quic", onOff: try arguments.bool("quic"))
        command.add("--udp", onOff: try arguments.bool("udp"))
        command.add("--isolate", onOff: try arguments.bool("isolate"))
        return .init(arguments: command)
    }
}
