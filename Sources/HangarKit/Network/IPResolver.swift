import Darwin
import Foundation
import HangarPackets
import HangarSupport

package enum IPResolver {
    /// Where macOS's own DHCP server (NAT networking) records its leases.
    private static let natLeasesPath = "/var/db/dhcpd_leases"
    /// A lease updated just before the VM started is the VM's own, from its last run.
    private static let leaseSlack: TimeInterval = 5
    private static let pollInterval = Duration.milliseconds(500)

    /// The VM's address once it has one, looked for until `timeout` runs out.
    package static func waitForAddress(for config: VMConfig, startedAt: Date, timeout: TimeInterval) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let ip = ipAddress(for: config, startedAt: startedAt) { return ip }
            guard Date() < deadline else { return nil }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return nil
            }
        }
    }

    package static func ipAddress(for config: VMConfig, startedAt: Date? = nil) -> String? {
        guard let mac = MACAddress.normalize(config.network.macAddress) else { return nil }

        switch config.network.mode {
        case .none:
            return nil
        case .managed:
            return currentLease(for: mac, reserved: config.network.ipAddress, startedAt: startedAt)
                ?? arpLookup(mac: mac)
        case .nat:
            let notShared: (String) -> Bool = { ip in
                IPv4Address(ip).map { !SharedNetwork.subnet.contains($0) } ?? false
            }
            return leaseLookup(mac: mac, where: notShared) ?? arpLookup(mac: mac, where: notShared)
        }
    }

    static func currentLease(for mac: String, reserved: String?, startedAt: Date?) -> String? {
        guard let lease = (try? SharedNetwork.readLeases())?[mac] else { return nil }
        if lease.ip != reserved.flatMap(IPv4Address.init), let startedAt,
            lease.updatedAt < startedAt.addingTimeInterval(-leaseSlack)
        {
            return nil
        }
        return lease.ip.description
    }

    static func leaseLookup(mac: String, where accept: (String) -> Bool = { _ in true }) -> String? {
        guard let text = try? String(contentsOfFile: natLeasesPath, encoding: .utf8) else { return nil }

        var ip: String?
        var hardware: String?
        var best: (ip: String, lease: UInt64)?
        var lease: UInt64 = 0

        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "{" {
                ip = nil
                hardware = nil
                lease = 0
            } else if line == "}" {
                if let ip, hardware == mac, accept(ip), lease >= (best?.lease ?? 0) {
                    best = (ip, lease)
                }
            } else if let value = line.value(after: "ip_address=") {
                ip = value
            } else if let value = line.value(after: "hw_address=") {
                hardware = value.split(separator: ",").last.flatMap { MACAddress.normalize(String($0)) }
            } else if let value = line.value(after: "lease=0x") {
                lease = UInt64(value, radix: 16) ?? 0
            }
        }

        return best?.ip
    }

    static func arpLookup(mac: String, where accept: (String) -> Bool = { _ in true }) -> String? {
        arpTable().first { $0.mac == mac && accept($0.ip) }?.ip
    }

    /// The kernel's ARP table, read the way `arp -an` reads it.
    static func arpTable() -> [(ip: String, mac: String)] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return [] }
        return entries(inRoutingMessages: Array(buffer.prefix(size)))
    }

    /// Each message is an `rt_msghdr` followed by a `sockaddr_in` (length, family, port, then the address at 4) and
    /// a `sockaddr_dl` (length, family, index, type, name length at 5, address length at 6, then name and address
    /// from 8), each padded to 4 bytes.
    static func entries(inRoutingMessages buffer: [UInt8]) -> [(ip: String, mac: String)] {
        let headerSize = MemoryLayout<rt_msghdr>.size
        func aligned(_ length: Int) -> Int { length > 0 ? (length + 3) & ~3 : 4 }
        var entries: [(ip: String, mac: String)] = []
        var offset = 0

        while offset + headerSize <= buffer.count {
            let length = Int(buffer[offset]) | Int(buffer[offset + 1]) << 8
            guard length >= headerSize, offset + length <= buffer.count else { break }
            let address = offset + headerSize
            if address + 8 <= offset + length, buffer[address + 1] == UInt8(AF_INET) {
                let ip = buffer[(address + 4)..<(address + 8)].map(String.init).joined(separator: ".")
                let link = address + aligned(Int(buffer[address]))
                if link + 8 <= offset + length, buffer[link + 1] == UInt8(AF_LINK) {
                    let nameLength = Int(buffer[link + 5])
                    let start = link + 8 + nameLength
                    if buffer[link + 6] == 6, start + 6 <= offset + length {
                        entries.append((ip, MACAddress.string(buffer[start..<(start + 6)])))
                    }
                }
            }
            offset += length
        }

        return entries
    }
}

extension String {
    fileprivate func value(after prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
