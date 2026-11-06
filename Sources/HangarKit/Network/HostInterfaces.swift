import Darwin
import HangarPackets
import HangarSupport

enum HostInterfaces {
    struct Address {
        let interface: String
        let address: IPv4Address
    }

    static func addresses() -> [Address] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }

        var result: [Address] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else {
                continue
            }
            let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            result.append(Address(interface: String(cString: entry.pointee.ifa_name), address: IPv4Address(value)))
        }
        return result
    }

    /// Bridges are skipped: an orphaned vmnet bridge from a crashed network daemon must not stop the next one.
    static func checkNoClash(with subnet: IPv4Subnet) throws {
        guard let clash = addresses().first(where: { !$0.interface.hasPrefix("bridge") && subnet.contains($0.address) })
        else { return }
        throw HangarError(
            "\(subnet) is also the network of \(clash.interface) (\(clash.address)) on this Mac, so the VMs couldn't reach it. Move Hangar's network to another subnet with all VMs stopped, e.g. hangar network set --subnet 10.80.0.1/24."
        )
    }
}
