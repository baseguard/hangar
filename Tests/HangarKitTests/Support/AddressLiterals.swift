import HangarPackets
import Testing

/// Reads an address a test spells out; a typo fails that test instead of crashing the whole run.
func ipv4(_ text: String) -> IPv4Address {
    if let address = IPv4Address(text) {
        return address
    }
    Issue.record("\(text) is not an IPv4 address")
    return IPv4Address(0)
}
