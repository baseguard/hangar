extension GuestOS {
    /// Where Hangar's agent writes the secrets' variables on Linux (`PROFILE_FILE` in its `trust.rs`); login shells
    /// read it, but a command run through the agent isn't one.
    static let linuxSecretsProfile = "/etc/profile.d/hangar-secrets.sh"

    /// A command line for the guest's own shell, run through Hangar's agent, with the VM's secret variables. Only
    /// Hangar's file is read on Linux, not a whole login, whose scripts can print notices into the output; on macOS
    /// zsh reads the variables from /etc/zshenv by itself.
    package func shellCommand(_ line: String) -> [String] {
        switch self {
        case .linux:
            let profile = Self.linuxSecretsProfile
            return ["/bin/sh", "-c", "[ -r \(profile) ] && . \(profile); \(line)"]
        case .macOS: return ["/bin/zsh", "-c", line]
        case .windows: return ["cmd.exe", "/d", "/s", "/c", line]
        }
    }
}
